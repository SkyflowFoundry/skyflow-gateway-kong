-- kong.plugins.skyflow-deidentify.handler
--
-- Konnect Dedicated Cloud Gateways build: a SINGLE self-contained handler with
-- all logic inlined (no auth/client/body/mapping sub-modules), so it can be
-- uploaded alongside schema.lua to a Konnect control plane. Only runtime libs
-- bundled with Kong (resty.http, cjson) are required.
--
-- Implemented in this build:
--   * access  -> full de-identify of request bodies (Skyflow Detect)
--   * response-> re-identify via `mapping_only` (pure, request-scoped map) OR
--                `reidentify_text` (resolves real VAULT_TOKENs through Skyflow
--                /v1/detect/reidentify/string -- works regardless of our map)
--   * auth    -> API key / static bearer token / service-account JWT (RS256
--                via Kong-bundled resty.openssl): mints and caches Skyflow
--                bearers per (SA, scope, ctx); supports scoped tokens
--                (credentials.role_ids) and context-aware authorization via a
--                `ctx` claim built from credentials.context (static) plus
--                credentials.context_headers (per-request), so vault policies
--                can condition access on $ctx.<attr>.
-- Documented follow-ups (degrade safely until added):
--   * reidentify strategy `detokenize` (vault /detokenize API)
--   * per-span concurrency, streaming `reassemble`
-- See docs/contributing/skyflow-integration.md and docs/contributing/development.md.

local http  = require "resty.http"
local cjson = require "cjson.safe"

-- Upstream LLM responses are commonly gzip-encoded; we must inflate before we
-- can parse/re-identify them. Kong bundles a gzip helper -- load it guarded so
-- the plugin still loads if the module path differs on a given build.
local ok_gzip, kgzip = pcall(require, "kong.tools.gzip")
local inflate_gzip = ok_gzip and kgzip and kgzip.inflate_gzip or nil

-- lua-resty-openssl ships with Kong Gateway (the core uses it). Load guarded so
-- the plugin still loads on a build without it -- SA-JWT auth then errors
-- cleanly at use time while api_key/token auth keeps working.
local ok_pkey, openssl_pkey     = pcall(require, "resty.openssl.pkey")
local ok_digest, openssl_digest = pcall(require, "resty.openssl.digest")

local kong = kong
local ngx  = ngx

local SkyflowDeidentify = { PRIORITY = 775, VERSION = "0.3.0" }

--==========================================================================--
-- Pure helpers (no Kong/ngx deps) — exercised offline via SkyflowDeidentify._test
--==========================================================================--

-- Parse a JSONPath-lite string into tokens. Supported: `$`, `.key`, `[*]`,
-- `[n]` (0-based), and `*` (any key). e.g. "$.messages[*].content[*].text".
local function parse_path(path)
  local p = path:gsub("^%$", "")           -- drop leading $
  p = p:gsub("%[(%*)%]", ".[*]")           -- [*] -> .[*]
  p = p:gsub("%[(%d+)%]", ".[%1]")         -- [n] -> .[n]
  p = p:gsub("^%.", "")                    -- drop leading dot
  local tokens = {}
  for tok in p:gmatch("[^%.]+") do
    tokens[#tokens + 1] = tok
  end
  return tokens
end

-- Walk `node` collecting string leaves at `tokens`, appending
-- { parent=<table>, key=<k>, text=<string> } slots to `out` (replace-ready).
local function walk(node, tokens, i, out)
  local tok = tokens[i]
  if tok == nil then return end
  local last = (i == #tokens)

  local function consider(parent, key)
    local v = (type(parent) == "table") and parent[key] or nil
    if last then
      if type(v) == "string" then
        out[#out + 1] = { parent = parent, key = key, text = v }
      end
    else
      walk(v, tokens, i + 1, out)
    end
  end

  if tok == "[*]" then
    if type(node) ~= "table" then return end
    for idx = 1, #node do consider(node, idx) end
  elseif tok == "*" then
    if type(node) ~= "table" then return end
    for k in pairs(node) do consider(node, k) end
  else
    local n = tok:match("^%[(%d+)%]$")
    if n then
      consider(node, tonumber(n) + 1)        -- JSONPath 0-based -> Lua 1-based
    else
      consider(node, tok)
    end
  end
end

-- Collect ALL replace-ready string spans for a list of path strings. No silent
-- cap: the caller enforces `max_spans` as a fail-closed limit, so we never
-- forward a partially de-identified body (that would leak the untouched extras).
local function collect_spans(doc, paths)
  local out = {}
  for _, path in ipairs(paths) do
    walk(doc, parse_path(path), 1, out)
  end
  return out
end

local PROFILE_PATHS = {
  openai = {
    request  = { "$.messages[*].content", "$.messages[*].content[*].text", "$.input", "$.prompt" },
    response = { "$.choices[*].message.content", "$.choices[*].text" },
  },
  anthropic = {
    request  = { "$.system", "$.messages[*].content[*].text", "$.messages[*].content" },
    response = { "$.content[*].text" },
  },
  mcp = {
    request  = { "$.params.arguments.*", "$.params.messages[*].content" },
    response = { "$.result.content[*].text", "$.result.*" },
  },
  generic = { request = {}, response = {} },
}

local function effective_paths(conf, phase)
  local base = (PROFILE_PATHS[conf.profile] or PROFILE_PATHS.generic)[phase] or {}
  local override = (phase == "request") and conf.request_json_paths or conf.response_json_paths
  if override and #override > 0 then
    if conf.profile == "generic" then return override end
    local merged = {}
    for _, s in ipairs(base) do merged[#merged + 1] = s end
    for _, s in ipairs(override) do merged[#merged + 1] = s end
    return merged
  end
  return base
end

-- Mask all but the last 4 characters of a value.
local function mask(value)
  value = tostring(value)
  local n = #value
  if n <= 4 then return string.rep("*", n) end
  return string.rep("*", n - 4) .. string.sub(value, n - 3)
end

-- Plain (non-pattern) substring replace.
local function plain_replace(s, needle, repl)
  if needle == nil or needle == "" then return s end
  local out, idx = {}, 1
  while true do
    local a, b = string.find(s, needle, idx, true)
    if not a then out[#out + 1] = string.sub(s, idx); break end
    out[#out + 1] = string.sub(s, idx, a - 1)
    out[#out + 1] = repl
    idx = b + 1
  end
  return table.concat(out)
end

-- Re-identify a single string from the request token->value map, honoring
-- per-entity treatment. `treatment_fn(entity)` -> "plain_text"|"masked"|"redacted".
local function reidentify_string(s, by_token, treatment_fn)
  -- replace longest tokens first to avoid partial overlaps
  local toks = {}
  for tok in pairs(by_token) do toks[#toks + 1] = tok end
  table.sort(toks, function(a, b) return #a > #b end)
  for _, tok in ipairs(toks) do
    local info = by_token[tok]
    local treatment = treatment_fn(info.entity)
    if treatment ~= "redacted" then
      local repl = (treatment == "masked") and mask(info.value) or info.value
      s = plain_replace(s, "[" .. tok .. "]", repl)
      s = plain_replace(s, tok, repl)
    end
  end
  return s
end

-- Base64url (RFC 4648 §5, unpadded) in pure Lua: used for JWT assembly. Pure
-- (no ngx dep) so the offline unit test can exercise it.
local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B64_REVERSE   -- lazily built decode table

local function b64url_encode(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i), s:byte(i + 1), s:byte(i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local quad = {
      math.floor(n / 262144) % 64, math.floor(n / 4096) % 64,
      math.floor(n / 64) % 64,     n % 64,
    }
    for j = 1, (c and 4) or (b and 3) or 2 do
      local d = quad[j]
      out[#out + 1] = B64_ALPHABET:sub(d + 1, d + 1)
    end
  end
  return table.concat(out)
end

local function b64url_decode(s)
  if type(s) ~= "string" then return nil end
  if not B64_REVERSE then
    B64_REVERSE = { ["+"] = 62, ["/"] = 63 }   -- accept the standard alphabet too
    for i = 1, 64 do B64_REVERSE[B64_ALPHABET:sub(i, i)] = i - 1 end
  end
  s = s:gsub("=+$", "")
  if #s % 4 == 1 then return nil end
  local out, n, bits = {}, 0, 0
  for i = 1, #s do
    local v = B64_REVERSE[s:sub(i, i)]
    if not v then return nil end
    n, bits = n * 64 + v, bits + 6
    if bits >= 8 then
      bits = bits - 8
      out[#out + 1] = string.char(math.floor(n / 2 ^ bits) % 256)
      n = n % 2 ^ bits
    end
  end
  return table.concat(out)
end

-- Extract the `exp` claim (unix seconds) from a JWT without full JSON parsing;
-- 0 when absent/unparseable. The token endpoint returns no expiresIn field, so
-- the bearer's own exp drives cache refresh.
local function jwt_exp(token)
  local payload = type(token) == "string" and token:match("^[^%.]+%.([^%.]+)")
  local raw = payload and b64url_decode(payload)
  if not raw then return 0 end
  return tonumber(raw:match('"exp"%s*:%s*(%d+)')) or 0
end

-- Merge static context attributes (credentials.context) with per-request
-- values pulled from headers (credentials.context_headers: attr -> header
-- name). Returns (ctx_table|nil, canonical_key) -- the canonical form (sorted
-- attr=value pairs) keys the token cache so a different caller context always
-- mints a distinct bearer. The ctx table becomes the assertion's `ctx` claim,
-- which Skyflow embeds in the bearer for $ctx.<attr> policy conditions.
local function build_ctx(static_map, header_map, get_header)
  local ctx, n = {}, 0
  if type(static_map) == "table" then
    for k, v in pairs(static_map) do ctx[k] = v; n = n + 1 end
  end
  if type(header_map) == "table" and get_header then
    for attr, header in pairs(header_map) do
      local v = get_header(header)
      if v and v ~= "" then
        if ctx[attr] == nil then n = n + 1 end
        ctx[attr] = v
      end
    end
  end
  if n == 0 then return nil, "" end
  local keys = {}
  for k in pairs(ctx) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(ctx[k]) end
  return ctx, table.concat(parts, "&")
end

-- Scoped-token role restriction: goes in the token-exchange BODY as `scope`
-- ("role:<id> role:<id>"), NOT in the signed assertion.
local function scope_from_roles(role_ids)
  if type(role_ids) ~= "table" or #role_ids == 0 then return nil end
  local parts = {}
  for _, r in ipairs(role_ids) do parts[#parts + 1] = "role:" .. r end
  return table.concat(parts, " ")
end

--==========================================================================--
-- Kong-coupled helpers
--==========================================================================--

local function base_url(conf)
  if conf.skyflow_base_url_override and conf.skyflow_base_url_override ~= "" then
    return (conf.skyflow_base_url_override:gsub("/$", ""))
  end
  return "https://" .. conf.cluster_id .. ".vault.skyflowapis.com"
end

--==========================================================================--
-- Service-account JWT auth (RS256 via Kong-bundled resty.openssl)
--
-- Assertion claims per the Skyflow contract: { iss=clientID, key=keyID,
-- aud=tokenURI, sub=clientID, exp=now+3600 } plus an optional `ctx` claim
-- (string or JSON object). Exchange: POST tokenURI with
-- { grant_type="urn:ietf:params:oauth:grant-type:jwt-bearer", assertion,
--   scope? } -> { accessToken, tokenType }. Bearers live ~60 min; the response
-- carries no expiry, so we decode the bearer's own exp claim.
--==========================================================================--

-- Per-worker caches. Keys change whenever the SA / roles / resolved ctx
-- change, so config updates and per-caller contexts mint naturally. Bounded by
-- wholesale reset -- simple, and a re-mint is cheap relative to eviction logic.
local PKEY_CACHE = {}                    -- privateKey PEM -> parsed pkey
local TOKEN_CACHE, TOKEN_CACHE_N = {}, 0 -- cache_key -> { token, exp }
local TOKEN_CACHE_MAX = 256
local JWT_HEADER_B64                     -- b64url of the fixed RS256 header

local function sign_assertion(sa, claims)
  if not (ok_pkey and ok_digest) then
    return nil, "resty.openssl unavailable: cannot sign service-account JWT"
  end
  local pkey = PKEY_CACHE[sa.privateKey]
  if not pkey then
    local err
    pkey, err = openssl_pkey.new(sa.privateKey)
    if not pkey then return nil, "invalid service-account privateKey: " .. tostring(err) end
    PKEY_CACHE[sa.privateKey] = pkey
  end
  JWT_HEADER_B64 = JWT_HEADER_B64 or b64url_encode('{"alg":"RS256","typ":"JWT"}')
  local unsigned = JWT_HEADER_B64 .. "." .. b64url_encode(cjson.encode(claims))
  local d, derr = openssl_digest.new("sha256")
  if not d then return nil, "digest init failed: " .. tostring(derr) end
  d:update(unsigned)
  local sig, serr = pkey:sign(d)
  if not sig then return nil, "RS256 sign failed: " .. tostring(serr) end
  return unsigned .. "." .. b64url_encode(sig)
end

-- Mint (or reuse) a Skyflow bearer for the configured service account.
-- Returns "Bearer <token>" or nil, err. The network hop happens at most once
-- per (SA, scope, ctx) per bearer lifetime per worker.
local function sa_bearer(conf, deadline)
  local c = conf.credentials
  local sa = cjson.decode(c.service_account_json)
  if type(sa) ~= "table" or not (sa.clientID and sa.keyID and sa.tokenURI and sa.privateKey) then
    return nil, "service_account_json must be JSON with clientID, keyID, tokenURI, privateKey"
  end

  local get_header = kong and kong.request and kong.request.get_header
  local ctx, ctx_key = build_ctx(c.context, c.context_headers, get_header)
  local scope = scope_from_roles(c.role_ids)
  local cache_key = table.concat({ sa.clientID, sa.keyID, scope or "", ctx_key }, "\n")

  local now = ngx.now()
  local hit = TOKEN_CACHE[cache_key]
  if hit and (hit.exp - (conf.token_skew_seconds or 300)) > now then
    return "Bearer " .. hit.token
  end

  local claims = {
    iss = sa.clientID, key = sa.keyID, aud = sa.tokenURI,
    sub = sa.clientID, exp = math.floor(now) + 3600,
  }
  claims.ctx = ctx   -- omitted entirely when no context is configured

  local assertion, aerr = sign_assertion(sa, claims)
  if not assertion then return nil, aerr end

  local body = cjson.encode({
    grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer",
    assertion  = assertion,
    scope      = scope,
  })

  local attempts, last_err = (conf.retries or 0) + 1, nil
  for i = 1, attempts do
    if deadline and ngx.now() >= deadline then return nil, "deadline exceeded minting SA bearer" end
    local httpc = http.new()
    httpc:set_timeout(conf.timeout_ms)
    local res, err = httpc:request_uri(sa.tokenURI, {
      method = "POST", body = body,
      headers = { ["Content-Type"] = "application/json" },
      ssl_verify = true,
      keepalive_timeout = conf.keepalive_idle_ms, keepalive_pool = conf.keepalive_pool_size,
    })
    if res and res.status == 200 then
      local data = cjson.decode(res.body)
      local token = data and data.accessToken
      if not token or token == "" then return nil, "token endpoint returned no accessToken" end
      local exp = jwt_exp(token)
      if exp == 0 then exp = math.floor(now) + 3600 end   -- documented default: 60 min
      if TOKEN_CACHE_N >= TOKEN_CACHE_MAX then TOKEN_CACHE, TOKEN_CACHE_N = {}, 0 end
      if not TOKEN_CACHE[cache_key] then TOKEN_CACHE_N = TOKEN_CACHE_N + 1 end
      TOKEN_CACHE[cache_key] = { token = token, exp = exp }
      local nctx = 0
      if ctx then for _ in pairs(ctx) do nctx = nctx + 1 end end
      kong.log.info("skyflow: minted SA bearer for ", sa.clientName or sa.clientID,
                    " (ctx attrs=", nctx, scope and ", scoped" or "",
                    ", ttl=", math.floor(exp - now), "s)")
      return "Bearer " .. token
    elseif res and res.status >= 400 and res.status < 500 and res.status ~= 429 then
      -- 4xx (bad assertion / enforceContextID unmet / malformed scope): the
      -- endpoint's message pinpoints the cause; retrying can't help.
      local detail = res.body and tostring(res.body):sub(1, 200) or ""
      return nil, "token endpoint status " .. res.status .. " (not retried): " .. detail
    else
      last_err = res and ("token endpoint status " .. res.status) or ("transport: " .. tostring(err))
      if i < attempts and (not deadline or ngx.now() < deadline) then ngx.sleep(0.1) end
    end
  end
  return nil, last_err or "SA token exchange failed"
end

-- Resolve the Authorization header value for the configured credential.
-- Precedence: api_key > token > service_account_json (schema enforces
-- only_one_of, so precedence only matters defensively).
local function auth_value(conf, deadline)
  local c = conf.credentials
  if c.api_key and c.api_key ~= "" then return "Bearer " .. c.api_key end
  if c.token and c.token ~= "" then return "Bearer " .. c.token end
  if c.service_account_json and c.service_account_json ~= "" then
    return sa_bearer(conf, deadline)
  end
  return nil, "no Skyflow credential configured"
end

-- POST JSON to Skyflow with a per-attempt timeout and deadline-bounded retries.
local function skyflow_post(conf, authz, path, payload, deadline)
  local url = base_url(conf) .. path
  local headers = { ["Authorization"] = authz, ["Content-Type"] = "application/json" }
  if conf.account_id and conf.account_id ~= "" then
    headers["X-SKYFLOW-ACCOUNT-ID"] = conf.account_id
  end
  local body = cjson.encode(payload)
  local attempts = (conf.retries or 0) + 1
  local last_err

  for i = 1, attempts do
    if ngx.now() >= deadline then return nil, "deadline exceeded" end
    local httpc = http.new()
    httpc:set_timeout(conf.timeout_ms)
    local res, err = httpc:request_uri(url, {
      method = "POST", headers = headers, body = body, ssl_verify = true,
      keepalive_timeout = conf.keepalive_idle_ms, keepalive_pool = conf.keepalive_pool_size,
    })
    if res and res.status == 200 then
      local data = cjson.decode(res.body)
      if not data then return nil, "non-JSON response from Skyflow" end
      if data.errors and #data.errors > 0 then return nil, "skyflow returned errors[]" end
      return data
    elseif res and res.status == 403 then
      return nil, "skyflow 403 (grant the Detect de-identify/re-identify permission)"
    elseif res and res.status >= 400 and res.status < 500 and res.status ~= 429 then
      -- client error (bad payload / vault_id / credential): retrying can't help,
      -- so fail fast instead of burning the whole deadline budget.
      return nil, "skyflow status " .. res.status .. " (client error, not retried)"
    else
      -- 429 / 5xx / transport: retryable within the deadline, with small backoff.
      last_err = res and ("skyflow status " .. res.status) or ("transport: " .. tostring(err))
      if i < attempts and ngx.now() < deadline then ngx.sleep(0.1) end
    end
  end
  return nil, last_err or "skyflow request failed"
end

-- Skyflow Detect enums are lowercase on the wire (e.g. name, email_address,
-- entity_unq_counter); config uses uppercase for readability, so downcase here.
local function lower_list(t)
  if not t or #t == 0 then return nil end
  local out = {}
  for i = 1, #t do out[i] = string.lower(t[i]) end
  return out
end

-- De-identify one text -> processed_text, entities[] (or nil, err).
local function deidentify_text(conf, authz, text, deadline)
  local d = conf.deidentify
  local payload = {
    text = text,
    vault_id = conf.vault_id,
    entity_types = lower_list(d.entities),
    token_type = { default = string.lower(d.token_format) },
    allow_regex_list = (#d.allow_regex > 0) and d.allow_regex or nil,
    restrict_regex_list = (#d.restrict_regex > 0) and d.restrict_regex or nil,
  }
  if d.shift_dates and d.shift_dates.enabled then
    payload.transformations = { shift_dates = {
      min_days = d.shift_dates.min_days, max_days = d.shift_dates.max_days,
      entities = lower_list(d.shift_dates.entities) } }
  end
  local data, err = skyflow_post(conf, authz, "/v1/detect/deidentify/string", payload, deadline)
  if not data then return nil, err end
  return data.processed_text or text, data.entities or {}
end

-- Re-identify one text via Skyflow: resolves real vault tokens embedded in the
-- text back to their original values. Only VAULT_TOKEN-format tokens exist in
-- the vault, so this is the vault-authoritative re-id path (independent of the
-- request-scoped map). Returns re-identified text (or nil, err).
local function skyflow_reidentify(conf, authz, text, deadline)
  local payload = { text = text, vault_id = conf.vault_id }
  local data, err = skyflow_post(conf, authz, "/v1/detect/reidentify/string", payload, deadline)
  if not data then return nil, err end
  return data.processed_text or data.text or text
end

local function has_body()
  local m = kong.request.get_method()
  return m == "POST" or m == "PUT" or m == "PATCH"
end

local function wants_json(conf, ct)
  if conf.content_type == "json" then return true end
  if conf.content_type == "text" then return false end
  ct = ct or ""
  return ct:find("application/json", 1, true) ~= nil or ct:find("+json", 1, true) ~= nil
end

-- Build a fail-closed/open ACTION for a de-identify failure. Does NOT call
-- kong.response.exit here -- the caller issues it outside the pcall (ngx.exit
-- unwinds via a sentinel error that a nested pcall would swallow).
local function fail_action(conf, ctx, err)
  kong.log.err("skyflow de-identify failed: ", err)
  ctx.posture = conf.on_skyflow_error
  if conf.on_skyflow_error == "deny" then
    return { deny = true, status = 502, body = { message = "request blocked: de-identification unavailable" } }
  end
  return { ok = true }   -- allow: forward the original body unchanged
end

--==========================================================================--
-- Lifecycle
--==========================================================================--

-- Exit-free access logic. Returns an ACTION table for the caller to enact:
--   { deny = true, status =, body = }  -> caller runs kong.response.exit(...)
--   { ok = true }                      -> proceed (body already rewritten here)
-- MUST NOT call kong.response.exit: it unwinds via a sentinel error that the
-- caller's pcall would swallow, silently defeating fail-closed. Body rewrites
-- (set_raw_body / enable_buffering) are plain PDK calls and are safe here.
-- kong.request.get_raw_body() returns nil when nginx spooled the request body to
-- a temp file instead of keeping it in memory -- which happens once the body
-- exceeds client_body_buffer_size. Small curls stay in memory; real API clients
-- (e.g. a coding agent sending a large system prompt + tool schemas) do not, so
-- without this fallback the plugin would deny every genuine agent request as
-- "body unavailable". Read the spooled file directly to recover the full body.
local function read_request_body()
  local raw = kong.request.get_raw_body()
  if raw ~= nil then return raw end
  local path = ngx.req.get_body_file()
  if not path then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function run_access(conf, ctx)
  local raw = read_request_body()
  if raw == nil then
    if conf.on_parse_error == "deny" then
      return { deny = true, status = 422, body = { message = "request blocked: body unavailable" } }
    end
    return { ok = true }
  end
  if #raw > conf.max_body_size then
    if conf.on_parse_error == "deny" then
      return { deny = true, status = 413, body = { message = "request blocked: body too large" } }
    end
    return { ok = true }
  end

  -- The deadline covers SA bearer minting too, so a hung token endpoint can't
  -- stall the request beyond deadline_ms.
  local deadline = ngx.now() + (conf.deadline_ms / 1000)
  local authz, aerr = auth_value(conf, deadline)
  if not authz then
    kong.log.err("skyflow auth error: ", aerr)
    -- auth failures ALWAYS fail closed (never forward raw PII), regardless of posture
    return { deny = true, status = 502, body = { message = "request blocked: auth unavailable" } }
  end

  local json_mode = wants_json(conf, kong.request.get_header("Content-Type"))

  -- Build the list of text spans to process.
  local doc, spans
  if json_mode then
    doc = cjson.decode(raw)
    if doc == nil then
      if conf.on_parse_error == "deny" then
        return { deny = true, status = 422, body = { message = "request blocked: invalid JSON" } }
      end
      return { ok = true }
    end
    spans = collect_spans(doc, effective_paths(conf, "request"))
  else
    spans = { { whole = true, text = raw } }
  end
  if #spans == 0 then return { ok = true } end

  -- Fail closed if the payload carries more sensitive-text fields than we will
  -- process. Never forward a partially de-identified body -- the untouched
  -- extras would leak upstream in the clear.
  if #spans > conf.max_spans then
    kong.log.err("skyflow: ", #spans, " spans exceed max_spans=", conf.max_spans, "; blocking request")
    return { deny = true, status = 413,
             body = { message = "request blocked: too many fields to de-identify (max_spans)" } }
  end

  if conf.deidentify.batch_mode == "joined" then
    kong.log.warn("skyflow: deidentify.batch_mode='joined' is not implemented; using per_span")
  end

  -- De-identify each span (sequential; deadline-bounded). Aggregate the map.
  local by_token, counts = {}, {}
  for _, span in ipairs(spans) do
    -- Skip empty spans: agent conversations carry messages with content "" (e.g.
    -- an assistant turn that only made tool calls). Skyflow Detect 400s on empty
    -- text, so leave it untouched rather than fail the whole request.
    if span.text == "" then
      span.processed = span.text
      goto continue
    end
    local processed, ents = deidentify_text(conf, authz, span.text, deadline)
    if not processed then
      return fail_action(conf, ctx, ents)   -- on failure `ents` is the error string
    end
    span.processed = processed
    for _, e in ipairs(ents) do
      if e.token then
        -- Detect returns the class as `entity_type` (e.g. "NAME"); keep the
        -- internal field `entity` that reidentify/treatment lookups expect.
        local etype = e.entity_type or e.entity
        by_token[e.token] = { value = e.value, entity = etype }
        counts[etype or "?"] = (counts[etype or "?"] or 0) + 1
      end
    end
    ::continue::
  end

  ctx.mapping = by_token
  ctx.entities_by_type = counts

  -- Rewrite the outbound body (unless dry-run).
  if not conf.dry_run then
    local newbody
    if json_mode then
      for _, span in ipairs(spans) do span.parent[span.key] = span.processed end
      -- Re-identification must buffer the whole response, which is impossible over
      -- a streamed (SSE) response: a vault token like [NAME_xjv74g] gets split
      -- across chunks and can't be matched. So force the upstream call
      -- non-streaming, remember the client wanted a stream, and re-emit the
      -- re-identified answer as SSE in :response(). (See demo/act2 — real coding
      -- agents always stream.)
      if doc.stream == true then
        ctx.client_stream = true
        doc.stream = false
        doc.stream_options = nil
      end
      local enc, eerr = cjson.encode(doc)
      if not enc then return fail_action(conf, ctx, "re-encode failed: " .. tostring(eerr)) end
      newbody = enc
    else
      newbody = spans[1].processed
    end
    kong.service.request.set_raw_body(newbody)
    kong.service.request.set_header("Content-Length", #newbody)
    -- Tokens went upstream -> the response is re-identifiable. This flag is
    -- independent of `by_token` (whose population depends on parsing the Detect
    -- entities[] shape); reidentify_text resolves via the vault and must not be
    -- gated on that map.
    ctx.deidentified = true
  end

  -- Buffer the response so this plugin's own response phase can re-identify it.
  -- Enable whenever we actually de-identified, independent of the reidentify
  -- setting, so a buffered body is available to read back.
  if ctx.deidentified and conf.reidentify.streaming ~= "passthrough" then
    -- Prefer an uncompressed response so the response phase can parse it. Only a
    -- hint -- some upstreams (e.g. ai-proxy's own call) compress anyway, so the
    -- response phase also inflates gzip defensively.
    kong.service.request.clear_header("Accept-Encoding")
    kong.service.request.enable_buffering()
  end

  return { ok = true }
end

function SkyflowDeidentify:access(conf)
  if not has_body() then return end
  local ctx = kong.ctx.plugin
  ctx.t0 = ngx.now()

  -- pcall wraps only the exit-free logic; all exits happen out here.
  local ok, action = pcall(run_access, conf, ctx)

  if not ok then
    kong.log.err("skyflow access internal error: ", tostring(action))
    ctx.posture = conf.on_skyflow_error
    if conf.on_skyflow_error == "deny" then
      return kong.response.exit(502, { message = "request blocked: de-identification unavailable" })
    end
    return  -- allow posture: fall through with the original body
  end

  if action and action.deny then
    return kong.response.exit(action.status, action.body)
  end
end

-- Pure: build the single streaming chunk from a buffered chat.completion. The
-- delta carries the whole answer -- content AND tool_calls, so an agent's tool
-- loop still works. Exposed via _test for offline unit testing.
local function sse_chunk(doc)
  local choice = (doc.choices and doc.choices[1]) or {}
  local delta  = choice.message or { role = "assistant", content = "" }
  -- OpenAI's streamed tool_call deltas carry an `index`; the buffered completion
  -- form omits it. Add it so the client can reassemble the tool calls.
  if type(delta.tool_calls) == "table" then
    for i, tc in ipairs(delta.tool_calls) do tc.index = i - 1 end
  end
  return {
    id = doc.id, object = "chat.completion.chunk",
    created = doc.created, model = doc.model,
    choices = { { index = 0, delta = delta, finish_reason = choice.finish_reason or "stop" } },
  }
end

-- Serialize a (re-identified) chat.completion as a minimal SSE stream, so a
-- streaming OpenAI client (e.g. a coding agent) gets the event-stream it asked
-- for even though the gateway had to buffer the full response to re-identify it.
-- One chunk + a [DONE] sentinel. The client renders it at once instead of
-- token-by-token, an acceptable trade for never leaking PII.
local function completion_to_sse(doc)
  return "data: " .. cjson.encode(sse_chunk(doc)) .. "\n\ndata: [DONE]\n\n"
end

-- True when the buffered upstream body is an Anthropic-native message (e.g.
-- ai-proxy with `llm_format: anthropic`, or a direct Anthropic upstream).
local function is_anthropic_message(doc)
  return doc.type == "message" and type(doc.content) == "table"
end

-- Anthropic Messages counterpart of completion_to_sse: re-emit a buffered
-- (re-identified) message as the event sequence Anthropic streaming clients
-- (e.g. Claude Code) require -- message_start, one start/delta/stop triplet
-- per content block (text and tool_use both supported, so agent tool loops
-- keep working), message_delta with the stop_reason, message_stop.
local function anthropic_message_to_sse(doc)
  -- cjson niceties guarded for non-Kong runtimes (offline tests stub cjson):
  -- array_mt makes the empty content encode as [], null keeps explicit nulls.
  local empty_array = cjson.array_mt and setmetatable({}, cjson.array_mt) or {}
  local null = cjson.null
  local function ev(name, data)
    return "event: " .. name .. "\ndata: " .. cjson.encode(data) .. "\n\n"
  end
  local out = { ev("message_start", { type = "message_start", message = {
    id = doc.id, type = "message", role = doc.role or "assistant",
    model = doc.model, content = empty_array,
    stop_reason = null, stop_sequence = null,
    usage = doc.usage or { input_tokens = 0, output_tokens = 0 },
  } }) }
  for i, block in ipairs(doc.content) do
    local idx = i - 1
    if block.type == "tool_use" then
      out[#out + 1] = ev("content_block_start", { type = "content_block_start", index = idx,
        content_block = { type = "tool_use", id = block.id, name = block.name, input = {} } })
      out[#out + 1] = ev("content_block_delta", { type = "content_block_delta", index = idx,
        delta = { type = "input_json_delta", partial_json = cjson.encode(block.input or {}) } })
    else
      out[#out + 1] = ev("content_block_start", { type = "content_block_start", index = idx,
        content_block = { type = "text", text = "" } })
      out[#out + 1] = ev("content_block_delta", { type = "content_block_delta", index = idx,
        delta = { type = "text_delta", text = block.text or "" } })
    end
    out[#out + 1] = ev("content_block_stop", { type = "content_block_stop", index = idx })
  end
  out[#out + 1] = ev("message_delta", { type = "message_delta",
    delta = { stop_reason = doc.stop_reason or "end_turn", stop_sequence = null },
    usage = { output_tokens = (doc.usage and doc.usage.output_tokens) or 0 } })
  out[#out + 1] = ev("message_stop", { type = "message_stop" })
  return table.concat(out)
end

-- Shape-appropriate SSE re-emit for a buffered doc.
local function doc_to_sse(doc)
  if is_anthropic_message(doc) then return anthropic_message_to_sse(doc) end
  return completion_to_sse(doc)
end

function SkyflowDeidentify:response(conf)
  if not conf.reidentify.enabled then return end

  local strat = conf.reidentify.strategy
  -- `detokenize` is a documented follow-up in this build; degrade safely.
  if strat ~= "mapping_only" and strat ~= "reidentify_text" then
    kong.log.warn("skyflow reidentify strategy '", strat,
                  "' not implemented in this build; returning tokenized response")
    if conf.reidentify.on_error == "deny" then
      return kong.response.exit(502, { message = "response blocked: re-identify unavailable" })
    end
    return
  end

  local ctx = kong.ctx.plugin
  local by_token = ctx.mapping or {}
  -- Gate per strategy. mapping_only substitutes from the request-scoped map, so
  -- it needs a non-empty map. reidentify_text resolves tokens via the vault and
  -- must NOT depend on that map (it can be empty even when de-identification
  -- happened) -- gate only on whether tokens actually went upstream.
  if strat == "mapping_only" then
    if not next(by_token) then return end
  elseif not ctx.deidentified then
    return
  end

  local status = kong.service.response.get_status()
  if not status or status < 200 or status >= 300 then return end

  -- reidentify_text calls the vault; resolve auth + a fresh deadline up front
  -- (deadline first: SA bearer minting is itself deadline-bounded).
  local authz, deadline
  if strat == "reidentify_text" then
    deadline = ngx.now() + (conf.deadline_ms / 1000)
    local aerr
    authz, aerr = auth_value(conf, deadline)
    if not authz then
      kong.log.err("skyflow re-identify auth error: ", aerr)
      if conf.reidentify.on_error == "deny" then
        return kong.response.exit(502, { message = "response blocked: re-identify unavailable" })
      end
      return
    end
    if next(conf.reidentify.entity_treatment) or conf.reidentify.default_treatment ~= "plain_text" then
      kong.log.warn("skyflow: reidentify_text restores plaintext from the vault; ",
                    "entity_treatment/masking is not applied (use mapping_only for treatments)")
    end
  end

  local treatment_fn = function(entity)
    return conf.reidentify.entity_treatment[entity] or conf.reidentify.default_treatment
  end

  -- Restore one text span. mapping_only substitutes from the request-scoped map
  -- (honors treatments); reidentify_text resolves vault tokens via Skyflow.
  local function restore(text)
    if strat == "reidentify_text" then
      return skyflow_reidentify(conf, authz, text, deadline)
    end
    return reidentify_string(text, by_token, treatment_fn)
  end

  local call_err
  local ok, perr = pcall(function()
    local raw = kong.service.response.get_raw_body()
    local ct  = kong.service.response.get_header("Content-Type")
    local enc = kong.service.response.get_header("Content-Encoding")
    -- Every "couldn't re-identify" path below sets call_err so the on_error
    -- gate applies uniformly -- fail-closed (deny) must not silently forward a
    -- tokenized body just because we couldn't read/parse it.
    if not raw or raw == "" then
      call_err = "no buffered response body"; return
    end

    -- Inflate gzip so the body is parseable. We emit the re-identified body
    -- UNcompressed and drop Content-Encoding (identity is always acceptable to
    -- a client that offered gzip), which avoids having to re-compress.
    local body, was_encoded = raw, false
    if enc and enc ~= "" then
      if enc:lower():find("gzip", 1, true) and inflate_gzip then
        local iok, dec = pcall(inflate_gzip, raw)
        if not iok or not dec then
          call_err = "gzip inflate failed"; return
        end
        body, was_encoded = dec, true
      else
        call_err = "unsupported Content-Encoding '" .. enc .. "'"; return
      end
    end

    local newbody
    local streamed = false
    if wants_json(conf, ct) then
      local doc = cjson.decode(body)
      if doc == nil then
        call_err = "response body not decodable JSON"; return
      end
      -- Restore tokens the model echoed back inside tool_call arguments (e.g. a
      -- username tokenized as a NAME inside a file path). The agent acts on these
      -- values, so they must be real, not tokens -- and collect_spans only covers
      -- message content, not tool_calls.
      local tool_changed = false
      if doc.choices then
        for _, ch in ipairs(doc.choices) do
          local tcs = ch.message and ch.message.tool_calls
          if type(tcs) == "table" then
            for _, tc in ipairs(tcs) do
              local fn = tc["function"]
              if fn and type(fn.arguments) == "string" and fn.arguments ~= "" then
                local restored, rerr = restore(fn.arguments)
                if not restored then call_err = rerr; return end
                fn.arguments = restored
                tool_changed = true
              end
            end
          end
        end
      end

      -- Anthropic-native messages: restore tokens inside tool_use inputs (the
      -- mirror of the OpenAI tool_calls handling above -- an agent acts on
      -- these values, so they must be real, not tokens).
      if is_anthropic_message(doc) then
        for _, block in ipairs(doc.content) do
          if block.type == "tool_use" and block.input ~= nil then
            local enc = cjson.encode(block.input)
            if enc and enc ~= "" then
              local restored, rerr = restore(enc)
              if not restored then call_err = rerr; return end
              block.input = cjson.decode(restored) or block.input
              tool_changed = true
            end
          end
        end
      end

      local spans = collect_spans(doc, effective_paths(conf, "response"))
      if #spans == 0 and not tool_changed then
        -- Nothing to re-identify (e.g. an empty response). If the client is
        -- streaming we STILL must hand back SSE, not the raw JSON completion, or
        -- the client stalls waiting for event-stream frames.
        if not ctx.client_stream then return end
        newbody = doc_to_sse(doc)
        streamed = true
      else
        for _, span in ipairs(spans) do
          if span.text ~= "" then
            local restored, rerr = restore(span.text)
            if not restored then call_err = rerr; return end
            span.parent[span.key] = restored
          end
        end
        newbody = cjson.encode(doc)
        -- Client asked to stream; re-emit the re-identified doc as SSE in the
        -- format the client's protocol expects (OpenAI chunk or Anthropic
        -- message events).
        if ctx.client_stream then
          newbody = doc_to_sse(doc)
          streamed = true
        end
      end
    else
      local restored, rerr = restore(body)
      if not restored then call_err = rerr; return end
      newbody = restored
    end

    if newbody then
      kong.response.set_raw_body(newbody)
      if was_encoded then kong.response.clear_header("Content-Encoding") end
      if streamed then kong.response.set_header("Content-Type", "text/event-stream") end
      kong.response.set_header("Content-Length", #newbody)
    end
  end)

  if (not ok) or call_err then
    kong.log.warn("skyflow re-identify error; returning tokenized response",
                  (not ok) and (": pcall: " .. tostring(perr))
                            or (call_err and (": " .. call_err) or ""))
    if conf.reidentify.on_error == "deny" then
      return kong.response.exit(502, { message = "response blocked: re-identify failed" })
    end
  end
end

function SkyflowDeidentify:log(conf)
  if conf.log and conf.log.detections then
    local ctx = kong.ctx.plugin
    kong.log.set_serialize_value("skyflow.entities_by_type", ctx.entities_by_type or {})
    kong.log.set_serialize_value("skyflow.posture", ctx.posture or "enforce")
  end
end

-- Exposed for offline unit testing of the pure algorithms (no Kong runtime).
SkyflowDeidentify._test = {
  parse_path        = parse_path,
  collect_spans     = collect_spans,
  effective_paths   = effective_paths,
  mask              = mask,
  plain_replace     = plain_replace,
  reidentify_string = reidentify_string,
  sse_chunk         = sse_chunk,
  is_anthropic_message     = is_anthropic_message,
  anthropic_message_to_sse = anthropic_message_to_sse,
  b64url_encode     = b64url_encode,
  b64url_decode     = b64url_decode,
  jwt_exp           = jwt_exp,
  build_ctx         = build_ctx,
  scope_from_roles  = scope_from_roles,
}

return SkyflowDeidentify
