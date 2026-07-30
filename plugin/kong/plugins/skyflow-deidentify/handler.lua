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
--                `ctx` claim assembled in layers -- context_json (arbitrary
--                nested JSON base), context (static attrs), context_headers
--                (per-request, client-supplied), context_kong (gateway-derived
--                facts, trusted, merged last) -- so vault policies can
--                condition access on $ctx.<attr> of any shape.
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
    -- The two trailing paths cover tool_result blocks (string form and
    -- text-block form) -- agent traffic surfaces most sensitive data THERE
    -- (file contents, command output), not in the user's typed message.
    request  = { "$.system", "$.messages[*].content[*].text", "$.messages[*].content",
                 "$.messages[*].content[*].content", "$.messages[*].content[*].content[*].text" },
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

-- Deep-copy a JSON-derived table (no cycles by construction).
local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep_copy(x) end
  return out
end

-- Set a dot-delimited path into a nested table: ctx_set(t, "org.unit", "x")
-- -> t.org.unit = "x". Intermediate non-tables are replaced.
local function ctx_set(tbl, path, value)
  local parts = {}
  for p in tostring(path):gmatch("[^%.]+") do parts[#parts + 1] = p end
  if #parts == 0 then return end
  local cur = tbl
  for i = 1, #parts - 1 do
    if type(cur[parts[i]]) ~= "table" then cur[parts[i]] = {} end
    cur = cur[parts[i]]
  end
  cur[parts[#parts]] = value
end

-- Deterministic serialization of an arbitrary JSON-shaped value: sorted keys,
-- type-tagged scalars (so "1" and 1 stay distinct). NOT valid JSON -- it only
-- keys the token cache, where any shape change must mint a fresh bearer.
local function canonical_ctx_key(v, out)
  out = out or {}
  local t = type(v)
  if t == "table" then
    if #v > 0 then
      out[#out + 1] = "["
      for i = 1, #v do canonical_ctx_key(v[i], out); out[#out + 1] = "," end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      out[#out + 1] = "{"
      for _, k in ipairs(keys) do
        out[#out + 1] = k .. "="
        canonical_ctx_key(v[k], out)
        out[#out + 1] = ","
      end
      out[#out + 1] = "}"
    end
  else
    out[#out + 1] = t:sub(1, 1) .. ":" .. tostring(v)
  end
  return out
end

-- Assemble the assertion's `ctx` claim. Skyflow accepts arbitrary JSON here
-- (policies traverse it as $ctx.a.b), so the claim is built in layers:
--   base   -- decoded credentials.context_json (any shape), deep-copied
--   layers -- flat attr(.path) -> value maps applied in order; LATER LAYERS
--             WIN, so callers must pass trusted (gateway-derived) maps after
--             client-supplied ones. Dot-delimited attrs nest.
-- Returns (ctx|nil, canonical_key); the key changes whenever the resolved
-- context does, so every distinct context mints a distinct bearer.
local function build_ctx(base, layers)
  local ctx = (type(base) == "table") and deep_copy(base) or {}
  for _, layer in ipairs(layers or {}) do
    if type(layer) == "table" then
      for attr, v in pairs(layer) do
        if v ~= nil and v ~= "" then ctx_set(ctx, attr, v) end
      end
    end
  end
  if next(ctx) == nil then return nil, "" end
  return ctx, table.concat(canonical_ctx_key(ctx))
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
local CTX_JSON_CACHE = {}                -- context_json string -> {ok=} | {err=}
local TOKEN_CACHE, TOKEN_CACHE_N = {}, 0 -- cache_key -> { token, exp }
local TOKEN_CACHE_MAX = 256
local JWT_HEADER_B64                     -- b64url of the fixed RS256 header

-- Parse credentials.context_json (arbitrary-shape ctx base), cached per
-- distinct config string. A non-object is a config error, surfaced as an auth
-- failure (fail closed) rather than silently minting context-less bearers.
local function ctx_base(context_json)
  if not context_json or context_json == "" then return nil end
  local hit = CTX_JSON_CACHE[context_json]
  if not hit then
    local decoded = cjson.decode(context_json)
    if type(decoded) == "table" then
      hit = { ok = decoded }
    else
      hit = { err = "credentials.context_json is not a JSON object" }
    end
    CTX_JSON_CACHE[context_json] = hit
  end
  return hit.ok, hit.err
end

-- Trusted, gateway-derived ctx sources (credentials.context_kong values).
-- These resolve via the PDK -- a client cannot spoof them -- so they are
-- merged LAST and win over header-supplied attributes.
local KONG_CTX_SOURCES = {
  consumer_id        = function() local c = kong.client.get_consumer(); return c and c.id end,
  consumer_username  = function() local c = kong.client.get_consumer(); return c and c.username end,
  consumer_custom_id = function() local c = kong.client.get_consumer(); return c and c.custom_id end,
  route_name         = function() local r = kong.router.get_route(); return r and r.name end,
  service_name       = function() local s = kong.router.get_service(); return s and s.name end,
  client_ip          = function() return kong.client.get_forwarded_ip() end,
}

-- Resolve an attr(.path) -> source-name map through KONG_CTX_SOURCES.
local function resolve_kong_ctx(kong_map)
  if type(kong_map) ~= "table" then return nil end
  local out = {}
  for attr, source in pairs(kong_map) do
    local fn = KONG_CTX_SOURCES[source]
    local ok, v = pcall(fn or function() end)
    if ok and v ~= nil and v ~= "" then out[attr] = v end
  end
  return out
end

-- Resolve an attr(.path) -> header-name map against the client request.
local function resolve_header_ctx(header_map)
  if type(header_map) ~= "table" then return nil end
  local get_header = kong and kong.request and kong.request.get_header
  if not get_header then return nil end
  local out = {}
  for attr, header in pairs(header_map) do
    local v = get_header(header)
    if v ~= nil and v ~= "" then out[attr] = v end
  end
  return out
end

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

-- ============================ STS (Profile B) ============================
-- Exchange the CALLER's IdP token for a Skyflow bearer (RFC 8693 delegation).
--
-- Differences from the service-account path below that matter operationally:
--   * the gateway holds NO Skyflow private key -- nothing to sign, nothing to
--     leak; it forwards an identity it was given
--   * ctx comes entirely from the IdP's claims (per the account's STS config
--     allowlist). The plugin's context/context_headers/context_kong settings
--     are IGNORED here: Skyflow silently drops any context supplied in the
--     exchange body, so gateway-asserted attributes are impossible -- put them
--     in the IdP token (Entra app roles / claims-mapping policy) instead.
--   * Skyflow records these as Auth Mode: STS with the human in Subject and
--     Context ID, while Actor stays the service account (delegation semantics)
--   * the minted bearer inherits the IdP token's `exp`, so its lifetime is
--     bounded by the caller's session, not a fixed hour

local STS_GRANT = "urn:ietf:params:oauth:grant-type:token-exchange"
local STS_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:jwt"  -- the only one accepted

-- How many attributes Skyflow actually put in the minted bearer's ctx. Logged
-- because the allowlist is an INTERSECTION: ctx = the STS config's
-- contextClaims that are also present in the caller's token. A claim the
-- policy needs but the IdP omitted disappears silently, so surface the count.
local function jwt_ctx_count(token)
  local payload = token and token:match("^[^.]+%.([^.]+)%.")
  local decoded = payload and b64url_decode(payload)
  local claims = decoded and cjson.decode(decoded)
  local ctx = type(claims) == "table" and claims.ctx
  if type(ctx) ~= "table" then return 0 end
  local n = 0
  for _ in pairs(ctx) do n = n + 1 end
  return n
end

-- Cheap, local pre-checks so a junk or misdirected token fails at the gateway
-- instead of costing a round trip. Signature verification is Skyflow's job
-- (it fetches the issuer's JWKS); this only rejects the obvious.
-- Returns claims, or nil + message + "identity". Every failure in here is the
-- CALLER's to fix -- a fresh sign-in, or pointing at the right gateway -- so it
-- must surface as 401, never as a 502 that implicates Skyflow.
local function precheck_caller_token(token, sts)
  local payload = token and token:match("^[^.]+%.([^.]+)%.")
  if not payload then return nil, "caller token is not a JWT", "identity" end
  local decoded = b64url_decode(payload)
  local claims = decoded and cjson.decode(decoded)
  if type(claims) ~= "table" then
    return nil, "caller token payload is not JSON", "identity"
  end
  if claims.exp and tonumber(claims.exp) and tonumber(claims.exp) <= ngx.now() then
    return nil, "caller identity token has expired; sign in again", "identity"
  end
  if sts.expected_issuer and sts.expected_issuer ~= "" and claims.iss ~= sts.expected_issuer then
    return nil, "caller token issuer mismatch", "identity"
  end
  if sts.expected_audience and sts.expected_audience ~= "" then
    local aud = claims.aud
    local ok = aud == sts.expected_audience
    if not ok and type(aud) == "table" then
      for _, a in ipairs(aud) do if a == sts.expected_audience then ok = true break end end
    end
    if not ok then return nil, "caller token audience mismatch", "identity" end
  end
  return claims
end

-- Exchange the caller's token; cache per caller token identity.
local function sts_bearer(conf, deadline)
  local sts = conf.credentials.sts
  if not sts.service_account_id or sts.service_account_id == "" then
    return nil, "credentials.sts.service_account_id is required"
  end

  local header = sts.token_header
  if header == nil or header == "" then header = "authorization" end
  local raw = kong.request.get_header(header)
  if not raw or raw == "" then
    return nil, "no caller identity token in '" .. header
                .. "'; this gateway cannot assert an identity on your behalf",
           "identity"
  end
  local token = raw:match("^[Bb]earer%s+(.+)$") or raw

  local claims, perr, pkind = precheck_caller_token(token, sts)
  if not claims then return nil, perr, pkind end

  -- one cached Skyflow bearer per (caller subject, token expiry): a new sign-in
  -- or a refreshed token mints a new one, and distinct callers never share
  local cache_key = "sts\n" .. sts.service_account_id .. "\n"
                    .. tostring(claims.sub or claims.oid or "?") .. "\n"
                    .. tostring(claims.exp or 0)
  local hit = TOKEN_CACHE[cache_key]
  if hit and hit.exp - (conf.token_skew_seconds or 300) > ngx.now() then
    return "Bearer " .. hit.token
  end

  local token_uri = sts.token_uri
  if not token_uri or token_uri == "" then
    token_uri = "https://manage.skyflowapis.com/v1/auth/sts/token"
  end
  local body = cjson.encode({
    grant_type = STS_GRANT,
    subject_token = token,
    subject_token_type = STS_TOKEN_TYPE,
    service_account_id = sts.service_account_id,
  })

  local attempts, last_err = (conf.retries or 0) + 1, nil
  for _ = 1, attempts do
    if deadline and ngx.now() >= deadline then
      return nil, "deadline exceeded exchanging caller identity"
    end
    local httpc = http.new()
    httpc:set_timeout(conf.timeout_ms)
    local res, err = httpc:request_uri(token_uri, {
      method = "POST", body = body,
      headers = { ["Content-Type"] = "application/json" },
      ssl_verify = true,
      keepalive_timeout = conf.keepalive_idle_ms, keepalive_pool = conf.keepalive_pool_size,
    })
    if res and res.status == 200 then
      local data = cjson.decode(res.body)
      local minted = data and data.accessToken
      if not minted or minted == "" then return nil, "sts endpoint returned no accessToken" end
      local exp = jwt_exp(minted)
      if exp == 0 then exp = math.floor(ngx.now()) + 300 end
      if TOKEN_CACHE_N >= TOKEN_CACHE_MAX then TOKEN_CACHE, TOKEN_CACHE_N = {}, 0 end
      if not TOKEN_CACHE[cache_key] then TOKEN_CACHE_N = TOKEN_CACHE_N + 1 end
      TOKEN_CACHE[cache_key] = { token = minted, exp = exp }
      kong.log.info("skyflow: exchanged caller identity for STS bearer (",
                    claims.preferred_username or claims.email or claims.sub or "?",
                    ", ctx attrs=", jwt_ctx_count(minted),
                    ", ttl=", math.floor(exp - ngx.now()), "s)")
      return "Bearer " .. minted
    elseif res and res.status >= 400 and res.status < 500 and res.status ~= 429 then
      -- 4xx here is a configuration OR identity problem, and the distinction
      -- matters to whoever gets the error. 401/403 means Skyflow refused the
      -- caller's token (bad signature, wrong audience, expired) -> the caller
      -- signs in again. Any other 4xx is our own STS misconfiguration -- no
      -- config for this (service account, issuer) pair, say -- and telling the
      -- caller to re-authenticate would send them chasing our bug.
      local kind = (res.status == 401 or res.status == 403) and "identity" or "config"
      return nil, "sts exchange rejected: HTTP " .. res.status .. " "
                  .. string.sub(res.body or "", 1, 180), kind
    else
      last_err = err or ("HTTP " .. tostring(res and res.status))
    end
  end
  return nil, "sts exchange failed: " .. tostring(last_err)
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

  local base, berr = ctx_base(c.context_json)
  if berr then return nil, berr end
  -- Layer order matters: static config, then client headers, then trusted
  -- gateway-derived facts last so a header can never override them.
  local ctx, ctx_key = build_ctx(base, {
    c.context,
    resolve_header_ctx(c.context_headers),
    resolve_kong_ctx(c.context_kong),
  })
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
  -- STS first when enabled: the caller's own identity is the strongest
  -- credential available, and it means no Skyflow key is used at all.
  if c.sts and c.sts.enabled then return sts_bearer(conf, deadline) end
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
--==========================================================================--
-- Binary attachments (images, PDFs)
--
-- The text path rewrites strings; an `image`/`document` content block carries
-- base64 bytes that no string API can touch, so those attachments reached the
-- provider unmodified. This closes that gap using Detect's **V2** file API,
-- which takes base64 in JSON (no multipart) and returns a redacted file --
-- exactly the shape an Anthropic block already gives us.
--
-- Verified against a live vault: a card image and a patient-intake PDF both
-- came back with every entity blacked out, and re-scanning the OUTPUT found
-- zero entities where the originals found six. Latency: images <1-3s, PDF ~10s.
--
-- Deliberate scoping:
--   * V2 is used ONLY here. Text stays on V1 -- it is tested and deployed, and
--     V2's text path would need per-entity `destination` values for
--     VAULT_TOKEN, which is a separate migration.
--   * Redaction is burned into pixels, so unlike text it is ONE-WAY: there is
--     nothing to re-identify on the response leg.
--   * ENTITY_UNIQUE_COUNTER (not VAULT_TOKEN) is used for files, which avoids
--     V2's destination requirement. Consequence: the original is not stored in
--     the vault, so there is no authorized-retrieval path for the unredacted
--     file yet. Vault-backed originals are a follow-up.

-- Anthropic media_type -> Detect V2 `dataFormat`. NOTE the enum is lowercase
-- here while every other V2 enum is SCREAMING_SNAKE ("PNG" is rejected).
-- webp is intentionally absent: Anthropic accepts it, Detect does not support
-- it, so it can never be de-identified -- it falls to the unsupported policy.
local MEDIA_FORMATS = {
  ["image/png"]  = "png",
  ["image/jpeg"] = "jpg",
  ["image/gif"]  = "gif",
  ["image/bmp"]  = "bmp",
  ["image/tiff"] = "tif",
  ["application/pdf"] = "pdf",
}

-- Collect every base64 attachment block, including ones nested in tool_result
-- content (an agent reading a file produces exactly that).
local function collect_media(data)
  local out = {}
  local function walk(blocks)
    if type(blocks) ~= "table" then return end
    for _, block in ipairs(blocks) do
      if type(block) == "table" then
        local t = block.type
        if t == "image" or t == "document" then
          out[#out + 1] = block
        elseif type(block.content) == "table" then
          walk(block.content)   -- tool_result carrying attachments
        end
      end
    end
  end
  for _, msg in ipairs(data.messages or {}) do
    if type(msg) == "table" and type(msg.content) == "table" then walk(msg.content) end
  end
  return out
end

-- Replace an attachment with a text marker so the turn still makes sense.
local function strip_media(block, why)
  for k in pairs(block) do block[k] = nil end
  block.type = "text"
  block.text = "[attachment removed before egress: " .. why .. "]"
end

-- Submit one file and poll to completion. Returns redacted base64, entity
-- count. Bounded by the request deadline; a timeout is an error, never a pass.
local function deidentify_file(conf, authz, b64, fmt, deadline)
  local m = conf.media or {}
  -- Attachment entity scope defaults to ALL, deliberately BROADER than the text
  -- path's list. Measured: the 8-entity text list found 4 entities in a card
  -- image where ALL found 6 (it missed CREDIT_CARD_EXPIRATION and more) -- and
  -- unlike a text span, nobody eyeballs an image before it egresses. Set
  -- media.entities to narrow it.
  local entities = {}
  for _, e in ipairs((m.entities and #m.entities > 0) and m.entities or {}) do
    entities[#entities + 1] = { entityType = e:upper(),
                                deidentificationType = "ENTITY_UNIQUE_COUNTER" }
  end
  if #entities == 0 then
    entities[1] = { entityType = "ALL", deidentificationType = "ENTITY_UNIQUE_COUNTER" }
  end

  local media_cfg = {
    -- BOTH fields are required once an image block exists: an absent
    -- outputProcessedImage is treated as false (not the documented true) and
    -- an absent maskingMethod defaults to NONE, which the API then refuses.
    image = { outputProcessedImage = true,
              maskingMethod = m.masking_method or "BLACKBOX" },
  }
  if fmt == "pdf" then
    media_cfg.document = { pdf = { processingMode = m.pdf_processing_mode or "OCR" } }
  end

  local detect = { entities = entities, returnEntities = "ALL" }
  -- Non-text objects. MUST be specific types, never `ALL`: measured, ALL/REDACT
  -- blacks out every detected object including ordinary text runs, so the
  -- provider receives a solid black rectangle -- protective but useless, and it
  -- also collapses the reported entity count to 1. FACE+SIGNATURE gives full
  -- PII text redaction (6/6 entities) AND face coverage, leaving labels and
  -- non-sensitive content readable.
  local obj_types = m.redact_object_types
  if obj_types and #obj_types > 0 then
    local objs = {}
    for _, t in ipairs(obj_types) do
      objs[#objs + 1] = { entityType = t, deidentificationType = "REDACT" }
    end
    detect.objectEntities = objs
  end

  local body = cjson.encode({
    dataSource = "BASE64", value = b64, dataFormat = fmt,
    configuration = { vaultId = conf.vault_id, detect = detect, media = media_cfg },
  })

  local httpc = http.new()
  httpc:set_timeout(conf.timeout_ms)
  local headers = { ["Authorization"] = authz, ["Content-Type"] = "application/json" }
  if conf.account_id and conf.account_id ~= "" then
    headers["X-SKYFLOW-ACCOUNT-ID"] = conf.account_id
  end

  local res, err = httpc:request_uri(base_url(conf) .. "/v2/detect/deidentify/file",
    { method = "POST", body = body, headers = headers, ssl_verify = true })
  if not res then return nil, nil, "submit failed: " .. tostring(err) end
  if res.status ~= 200 then
    return nil, nil, "submit HTTP " .. res.status .. " " .. string.sub(res.body or "", 1, 160)
  end
  local run_id = (cjson.decode(res.body) or {}).runId
  if not run_id then return nil, nil, "no runId in submit response" end

  local poll_url = base_url(conf) .. "/v2/detect/runs/" .. run_id
                   .. "?vaultId=" .. conf.vault_id
  local interval = (m.poll_interval_ms or 500) / 1000
  while true do
    if deadline and ngx.now() >= deadline then
      return nil, nil, "deadline exceeded while de-identifying attachment"
    end
    ngx.sleep(interval)
    local p = http.new()
    p:set_timeout(conf.timeout_ms)
    local pr, perr = p:request_uri(poll_url, { method = "GET", headers = headers, ssl_verify = true })
    if not pr then return nil, nil, "poll failed: " .. tostring(perr) end
    if pr.status ~= 200 then
      return nil, nil, "poll HTTP " .. pr.status .. " " .. string.sub(pr.body or "", 1, 160)
    end
    local run = cjson.decode(pr.body) or {}
    if run.status == "SUCCESS" then
      local redacted, n_entities
      for _, o in ipairs(run.output or {}) do
        if o.processedFileType == "REDACTED_FILE" and o.processedFile then
          redacted = o.processedFile
        elseif o.processedFileType == "ENTITIES" and o.processedFile then
          -- detections live in this attachment, not the top-level `entities`
          -- array (which comes back empty for files)
          local decoded = b64url_decode((o.processedFile:gsub("+", "-"):gsub("/", "_")))
          local list = decoded and cjson.decode(decoded)
          if type(list) == "table" then n_entities = #list end
        end
      end
      if not redacted then return nil, nil, "run succeeded with no REDACTED_FILE output" end
      return redacted, n_entities, nil
    elseif run.status == "FAILED" then
      return nil, nil, "detect run failed: " .. tostring(run.message)
    end
  end
end

-- Apply the media policy to every attachment in the request.
-- Returns processed count, stripped count, or nil+err when failing closed.
local function process_media(conf, authz, data, deadline)
  local m = conf.media or {}
  local mode = m.mode or "deidentify"
  if mode == "passthrough" then return 0, 0 end

  local blocks = collect_media(data)
  if #blocks == 0 then return 0, 0 end

  local processed, stripped = 0, 0
  for _, block in ipairs(blocks) do
    local src = block.source or {}
    local fmt = MEDIA_FORMATS[src.media_type or ""]
    local unsupported =
      (src.type ~= "base64") and ("source type '" .. tostring(src.type) .. "' cannot be inspected")
      or (not fmt) and ("format " .. tostring(src.media_type) .. " is not supported for de-identification")
      or nil

    if mode == "strip" then
      strip_media(block, "policy: attachments stripped")
      stripped = stripped + 1
    elseif unsupported then
      -- Never forward something we could not inspect.
      if (m.unsupported or "strip") == "block" then return nil, nil, unsupported end
      strip_media(block, unsupported)
      stripped = stripped + 1
    elseif mode == "block" then
      return nil, nil, "policy: attachments are not permitted"
    else
      local size = #(src.data or "")
      if m.max_file_bytes and m.max_file_bytes > 0 and size > m.max_file_bytes then
        return nil, nil, "attachment exceeds max_file_bytes (" .. size .. " base64 bytes)"
      end
      local redacted, n, err = deidentify_file(conf, authz, src.data, fmt, deadline)
      if not redacted then return nil, nil, err end
      src.data = redacted
      processed = processed + 1
      kong.log.info("skyflow: de-identified ", fmt, " attachment (",
                    n or "?", " entities redacted)")
    end
  end
  return processed, stripped
end

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
  local authz, aerr, akind = auth_value(conf, deadline)
  if not authz then
    -- Auth failures ALWAYS fail closed -- never forward raw PII -- regardless of
    -- posture. But WHICH failure matters to whoever reads the error:
    --
    --   identity -> 401. The caller's token is missing, expired, or meant for a
    --     different gateway. They fix it by signing in again. Reporting this as
    --     502 sends them to investigate Skyflow for their own expired session,
    --     which is exactly the wrong place -- and a client that retries on 502
    --     but re-authenticates on 401 will spin forever on the wrong one.
    --   anything else -> 502. Skyflow is unreachable, or our own STS config is
    --     wrong; telling the caller to re-authenticate would send them chasing
    --     our bug.
    if akind == "identity" then
      kong.log.warn("skyflow: caller identity rejected: ", aerr)
      return { deny = true, status = 401,
               body = { message = "request blocked: " .. tostring(aerr) } }
    end
    kong.log.err("skyflow auth error: ", aerr)
    return { deny = true, status = 502, body = { message = "request blocked: auth unavailable" } }
  end

  -- Strip the credential we just consumed, so it cannot egress to the model
  -- provider. This is NOT belt-and-braces: Kong's own ai-proxy drivers add their
  -- provider credential with set_header and never clear an inbound
  -- Authorization -- verified in kong/llm/drivers/anthropic.lua, whose
  -- configure_request only ever calls set_header(auth_header_name, ...). Since
  -- Anthropic authenticates with x-api-key rather than Authorization, nothing
  -- downstream overwrites ours, and the caller's enterprise IdP token would ride
  -- all the way to api.anthropic.com. (The OpenAI route happens to escape this
  -- because its credential occupies Authorization itself -- an accident, not a
  -- design.) Nothing inward needs it: internal routes are guarded by source IP,
  -- and the STS bearer we minted travels in our own request to Skyflow.
  if kong.service and kong.service.request and kong.service.request.clear_header then
    kong.service.request.clear_header("Authorization")
  end

  -- Will this request's response actually be re-emitted as SSE by :response()?
  -- Downgrading the client's stream is only safe if the answer is yes; otherwise
  -- we would strip `stream: true` and then leave nobody to turn the buffered JSON
  -- back into an event stream, and a client that asked for text/event-stream
  -- hangs or gets JSON. The /probe route (reidentify disabled) is exactly that
  -- case, so it must keep streaming straight through -- showing the caller the
  -- tokenized SSE the provider produced, which is that route's whole purpose.
  local will_reemit = conf.reidentify.enabled
                      and conf.reidentify.streaming ~= "passthrough"

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

  -- Binary attachments first: they are the one payload shape the text path
  -- cannot touch, and a redacted image changes `doc`, so this must happen
  -- before the body is re-encoded. Runs even when there are no text spans --
  -- an image-only turn still needs protecting.
  local media_processed, media_stripped = 0, 0
  if json_mode then
    local media_err
    media_processed, media_stripped, media_err = process_media(conf, authz, doc, deadline)
    if not media_processed then
      kong.log.err("skyflow: attachment policy blocked request: ", tostring(media_err))
      return { deny = true, status = 415,
               body = { message = "request blocked: " .. tostring(media_err) } }
    end
    if media_processed > 0 or media_stripped > 0 then
      kong.log.info("skyflow: attachments -- ", media_processed, " de-identified, ",
                    media_stripped, " stripped")
    end
  end

  if #spans == 0 then
    -- No text to process, but an attachment may have been rewritten above, so
    -- the body still has to go out re-encoded. Mirrors the main rewrite path
    -- below, including the force-non-streaming behaviour.
    if (media_processed > 0 or media_stripped > 0) and not conf.dry_run then
      if doc.stream == true and will_reemit then
        ctx.client_stream = true
        doc.stream = false
        doc.stream_options = nil
      end
      local enc, eerr = cjson.encode(doc)
      if not enc then return fail_action(conf, ctx, "re-encode failed: " .. tostring(eerr)) end
      kong.service.request.set_raw_body(enc)
      kong.service.request.set_header("Content-Length", #enc)
      -- Mark the request processed even though no TEXT span was tokenized.
      -- Without this the response phase bails at the `not ctx.deidentified`
      -- gate, and two things break: (1) we just downgraded the client's stream
      -- to a buffered request, so nobody re-emits SSE and a streaming client
      -- hangs -- an image pasted with no accompanying text does exactly this;
      -- (2) in a multi-turn session the model echoes tokens minted on EARLIER
      -- turns, and those would come back to the caller unresolved.
      ctx.deidentified = true
      if conf.reidentify.streaming ~= "passthrough" then
        kong.service.request.clear_header("Accept-Encoding")
        kong.service.request.enable_buffering()
      end
    end
    return { ok = true }
  end

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
      if doc.stream == true and will_reemit then
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
  local idx = -1
  for _, block in ipairs(doc.content) do
    -- Emit each block AS ITS OWN TYPE. Collapsing everything to `text` looks
    -- harmless but corrupts the client's stored history: a `thinking` block has
    -- no `text` field, so it became `text: ""`, the client saved an empty text
    -- block, and replaying that history made the API reject the NEXT turn with
    -- "text content blocks must be non-empty". Extended thinking is on by
    -- default in some clients, so this hit every multi-turn conversation.
    if block.type == "tool_use" then
      idx = idx + 1
      out[#out + 1] = ev("content_block_start", { type = "content_block_start", index = idx,
        content_block = { type = "tool_use", id = block.id, name = block.name, input = {} } })
      out[#out + 1] = ev("content_block_delta", { type = "content_block_delta", index = idx,
        delta = { type = "input_json_delta", partial_json = cjson.encode(block.input or {}) } })
      out[#out + 1] = ev("content_block_stop", { type = "content_block_stop", index = idx })

    elseif block.type == "thinking" then
      -- Reasoning text is passed through VERBATIM and never re-identified: the
      -- block carries a signature the provider verifies when the client replays
      -- it, so altering the text would invalidate the turn. Any vault tokens in
      -- reasoning therefore stay tokenized -- cosmetic, and the safe direction.
      idx = idx + 1
      out[#out + 1] = ev("content_block_start", { type = "content_block_start", index = idx,
        content_block = { type = "thinking", thinking = "" } })
      out[#out + 1] = ev("content_block_delta", { type = "content_block_delta", index = idx,
        delta = { type = "thinking_delta", thinking = block.thinking or "" } })
      if block.signature then
        out[#out + 1] = ev("content_block_delta", { type = "content_block_delta", index = idx,
          delta = { type = "signature_delta", signature = block.signature } })
      end
      out[#out + 1] = ev("content_block_stop", { type = "content_block_stop", index = idx })

    elseif block.type == "redacted_thinking" then
      idx = idx + 1
      out[#out + 1] = ev("content_block_start", { type = "content_block_start", index = idx,
        content_block = { type = "redacted_thinking", data = block.data or "" } })
      out[#out + 1] = ev("content_block_stop", { type = "content_block_stop", index = idx })

    elseif type(block.text) == "string" and block.text ~= "" then
      idx = idx + 1
      out[#out + 1] = ev("content_block_start", { type = "content_block_start", index = idx,
        content_block = { type = "text", text = "" } })
      out[#out + 1] = ev("content_block_delta", { type = "content_block_delta", index = idx,
        delta = { type = "text_delta", text = block.text } })
      out[#out + 1] = ev("content_block_stop", { type = "content_block_stop", index = idx })
    end
    -- anything else (including an empty text block) is dropped rather than
    -- emitted as an empty block the client would persist and replay
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
    local aerr, akind
    authz, aerr, akind = auth_value(conf, deadline)
    if not authz then
      -- Same 401/502 split as the request leg. Reaching here with an identity
      -- failure means the caller's token expired DURING generation -- rare, but
      -- a long response makes it possible, and "sign in again" is the honest
      -- answer rather than blaming Skyflow.
      if akind == "identity" then
        kong.log.warn("skyflow: caller identity rejected on the response leg: ", aerr)
        if conf.reidentify.on_error == "deny" then
          return kong.response.exit(401, { message = "response blocked: " .. tostring(aerr) })
        end
        return
      end
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
      -- Tool inputs (OpenAI tool_calls / Anthropic tool_use): treatment is a
      -- policy choice (reidentify.tool_inputs).
      --   tokenized  (default) -- leave the model's tokens in place. The
      --     gateway is the trust boundary: tools fan data out to arbitrary
      --     external services (web search, APIs, files), so real values must
      --     only materialize at the gateway on authorized egress, never
      --     inside agent-land. A tool acting on a token simply no-ops.
      --   plain_text -- restore real values before the agent executes the
      --     tool (trust-the-client deployments; collect_spans only covers
      --     message content, so this needs its own pass).
      local restore_tools = conf.reidentify.tool_inputs == "plain_text"
      local tool_changed = false
      if restore_tools and doc.choices then
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

      -- Anthropic-native messages: same policy, tool_use.input form.
      if restore_tools and is_anthropic_message(doc) then
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
  ctx_set           = ctx_set,
  deep_copy         = deep_copy,
  canonical_ctx_key = canonical_ctx_key,
  scope_from_roles  = scope_from_roles,
  precheck_caller_token = precheck_caller_token,
}

return SkyflowDeidentify
