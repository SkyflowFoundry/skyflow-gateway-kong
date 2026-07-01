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
--   * auth    -> API key / static bearer token
-- Documented follow-ups (degrade safely until added):
--   * reidentify strategy `detokenize` (vault /detokenize API)
--   * service-account JWT auth (RS256 via resty.openssl)
--   * per-span concurrency, streaming `reassemble`
-- See docs/03 and docs/05.

local http  = require "resty.http"
local cjson = require "cjson.safe"

-- Upstream LLM responses are commonly gzip-encoded; we must inflate before we
-- can parse/re-identify them. Kong bundles a gzip helper -- load it guarded so
-- the plugin still loads if the module path differs on a given build.
local ok_gzip, kgzip = pcall(require, "kong.tools.gzip")
local inflate_gzip = ok_gzip and kgzip and kgzip.inflate_gzip or nil

local kong = kong
local ngx  = ngx

local SkyflowDeidentify = { PRIORITY = 775, VERSION = "0.2.0" }

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

--==========================================================================--
-- Kong-coupled helpers
--==========================================================================--

local function base_url(conf)
  if conf.skyflow_base_url_override and conf.skyflow_base_url_override ~= "" then
    return (conf.skyflow_base_url_override:gsub("/$", ""))
  end
  return "https://" .. conf.cluster_id .. ".vault.skyflowapis.com"
end

-- Resolve the Authorization header value for the configured credential.
local function auth_value(conf)
  local c = conf.credentials
  if c.api_key and c.api_key ~= "" then return "Bearer " .. c.api_key end
  if c.token and c.token ~= "" then return "Bearer " .. c.token end
  if c.service_account_json and c.service_account_json ~= "" then
    return nil, "service-account JWT auth is not implemented in the Konnect "
             .. "single-file build; use credentials.api_key or credentials.token"
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
local function run_access(conf, ctx)
  local raw = kong.request.get_raw_body()
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

  local authz, aerr = auth_value(conf)
  if not authz then
    kong.log.err("skyflow auth error: ", aerr)
    -- auth failures ALWAYS fail closed (never forward raw PII), regardless of posture
    return { deny = true, status = 502, body = { message = "request blocked: auth unavailable" } }
  end

  local deadline = ngx.now() + (conf.deadline_ms / 1000)
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
  end

  ctx.mapping = by_token
  ctx.entities_by_type = counts

  -- Rewrite the outbound body (unless dry-run).
  if not conf.dry_run then
    local newbody
    if json_mode then
      for _, span in ipairs(spans) do span.parent[span.key] = span.processed end
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

  -- reidentify_text calls the vault; resolve auth + a fresh deadline up front.
  local authz, deadline
  if strat == "reidentify_text" then
    local aerr
    authz, aerr = auth_value(conf)
    if not authz then
      kong.log.err("skyflow re-identify auth error: ", aerr)
      if conf.reidentify.on_error == "deny" then
        return kong.response.exit(502, { message = "response blocked: re-identify unavailable" })
      end
      return
    end
    deadline = ngx.now() + (conf.deadline_ms / 1000)
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
    if not raw or raw == "" then
      kong.log.notice("skyflow reidentify: no buffered response body; skipping")
      return
    end

    -- Inflate gzip so the body is parseable. We emit the re-identified body
    -- UNcompressed and drop Content-Encoding (identity is always acceptable to
    -- a client that offered gzip), which avoids having to re-compress.
    local body, was_encoded = raw, false
    if enc and enc ~= "" then
      if enc:lower():find("gzip", 1, true) and inflate_gzip then
        local iok, dec = pcall(inflate_gzip, raw)
        if not iok or not dec then
          kong.log.notice("skyflow reidentify: gzip inflate failed; skipping"); return
        end
        body, was_encoded = dec, true
      else
        kong.log.notice("skyflow reidentify: unsupported Content-Encoding '", enc, "'; skipping"); return
      end
    end

    local newbody
    if wants_json(conf, ct) then
      local doc = cjson.decode(body)
      if doc == nil then
        kong.log.notice("skyflow reidentify: body not decodable JSON (len=", #body, "); skipping"); return
      end
      local spans = collect_spans(doc, effective_paths(conf, "response"))
      if #spans == 0 then return end
      for _, span in ipairs(spans) do
        local restored, rerr = restore(span.text)
        if not restored then call_err = rerr; return end
        span.parent[span.key] = restored
      end
      newbody = cjson.encode(doc)
    else
      local restored, rerr = restore(body)
      if not restored then call_err = rerr; return end
      newbody = restored
    end

    if newbody then
      kong.response.set_raw_body(newbody)
      if was_encoded then kong.response.clear_header("Content-Encoding") end
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
}

return SkyflowDeidentify
