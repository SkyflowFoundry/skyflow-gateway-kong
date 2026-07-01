-- kong.plugins.skyflow-reidentify.handler
--
-- Response-phase re-identification, split out from skyflow-deidentify so it can
-- run AFTER ai-proxy.
--
-- Why a separate plugin: Kong runs every phase highest-priority-first, and a
-- plugin has ONE priority for all phases. So a single plugin cannot both
-- de-identify BEFORE ai-proxy (access) and re-identify AFTER it (response) --
-- whichever order the priority picks applies to both phases. This plugin has a
-- LOWER priority (760) than ai-proxy (770), so in the response phase it runs
-- after ai-proxy has produced the final body. Pair it with skyflow-deidentify
-- (higher priority, de-identify only) on the same route. This mirrors Kong's own
-- ai-request-transformer / ai-response-transformer split.
--
-- Vault-backed only: resolves real VAULT_TOKENs via /v1/detect/reidentify/string,
-- which needs no request-scoped state, so it works cleanly as a separate plugin.
-- It runs only when skyflow-deidentify signalled a de-identified request via
-- kong.ctx.shared.skyflow_deidentified.

local http  = require "resty.http"
local cjson = require "cjson.safe"

-- Upstream LLM responses are commonly gzip-encoded; inflate before parsing.
local ok_gzip, kgzip = pcall(require, "kong.tools.gzip")
local inflate_gzip = ok_gzip and kgzip and kgzip.inflate_gzip or nil

local kong = kong
local ngx  = ngx

local SkyflowReidentify = { PRIORITY = 760, VERSION = "0.1.0" }

--==========================================================================--
-- Shared helpers (kept in sync with skyflow-deidentify; self-contained per the
-- Konnect custom-plugin constraint -- no cross-plugin module requires).
--==========================================================================--

local function parse_path(path)
  local p = path:gsub("^%$", "")
  p = p:gsub("%[(%*)%]", ".[*]")
  p = p:gsub("%[(%d+)%]", ".[%1]")
  p = p:gsub("^%.", "")
  local tokens = {}
  for tok in p:gmatch("[^%.]+") do
    tokens[#tokens + 1] = tok
  end
  return tokens
end

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
      consider(node, tonumber(n) + 1)
    else
      consider(node, tok)
    end
  end
end

local function collect_spans(doc, paths)
  local out = {}
  for _, path in ipairs(paths) do
    walk(doc, parse_path(path), 1, out)
  end
  return out
end

local PROFILE_RESPONSE_PATHS = {
  openai    = { "$.choices[*].message.content", "$.choices[*].text" },
  anthropic = { "$.content[*].text" },
  mcp       = { "$.result.content[*].text", "$.result.*" },
  generic   = {},
}

local function effective_paths(conf)
  local base = PROFILE_RESPONSE_PATHS[conf.profile] or PROFILE_RESPONSE_PATHS.generic
  local override = conf.response_json_paths
  if override and #override > 0 then
    if conf.profile == "generic" then return override end
    local merged = {}
    for _, s in ipairs(base) do merged[#merged + 1] = s end
    for _, s in ipairs(override) do merged[#merged + 1] = s end
    return merged
  end
  return base
end

local function base_url(conf)
  if conf.skyflow_base_url_override and conf.skyflow_base_url_override ~= "" then
    return (conf.skyflow_base_url_override:gsub("/$", ""))
  end
  return "https://" .. conf.cluster_id .. ".vault.skyflowapis.com"
end

local function auth_value(conf)
  local c = conf.credentials
  if c.api_key and c.api_key ~= "" then return "Bearer " .. c.api_key end
  if c.token and c.token ~= "" then return "Bearer " .. c.token end
  if c.service_account_json and c.service_account_json ~= "" then
    return nil, "service-account JWT auth is not implemented in this build; "
             .. "use credentials.api_key or credentials.token"
  end
  return nil, "no Skyflow credential configured"
end

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
      return nil, "skyflow 403 (grant the Detect reidentify/detokenize permission)"
    elseif res and res.status >= 400 and res.status < 500 and res.status ~= 429 then
      return nil, "skyflow status " .. res.status .. " (client error, not retried)"
    else
      last_err = res and ("skyflow status " .. res.status) or ("transport: " .. tostring(err))
      if i < attempts and ngx.now() < deadline then ngx.sleep(0.1) end
    end
  end
  return nil, last_err or "skyflow request failed"
end

-- Resolve real vault tokens embedded in `text` back to their values. Returns
-- re-identified text (or nil, err). Re-id returns the result under `text`
-- (de-id uses `processed_text`); accept either.
local function skyflow_reidentify(conf, authz, text, deadline)
  local payload = { text = text, vault_id = conf.vault_id }
  local data, err = skyflow_post(conf, authz, "/v1/detect/reidentify/string", payload, deadline)
  if not data then return nil, err end
  return data.processed_text or data.text or text
end

local function wants_json(conf, ct)
  if conf.content_type == "json" then return true end
  if conf.content_type == "text" then return false end
  ct = ct or ""
  return ct:find("application/json", 1, true) ~= nil or ct:find("+json", 1, true) ~= nil
end

--==========================================================================--
-- Lifecycle -- response phase only (runs AFTER ai-proxy due to lower priority).
--==========================================================================--

function SkyflowReidentify:response(conf)
  -- Only act when skyflow-deidentify de-identified this request; otherwise there
  -- are no vault tokens to restore (and buffering may not be enabled).
  if not kong.ctx.shared.skyflow_deidentified then return end

  local status = kong.service.response.get_status()
  if not status or status < 200 or status >= 300 then return end

  local authz, aerr = auth_value(conf)
  if not authz then
    kong.log.err("skyflow-reidentify auth error: ", aerr)
    if conf.on_error == "deny" then
      return kong.response.exit(502, { message = "response blocked: re-identify unavailable" })
    end
    return
  end
  local deadline = ngx.now() + (conf.deadline_ms / 1000)

  local call_err
  local ok, perr = pcall(function()
    local raw = kong.service.response.get_raw_body()
    local ct  = kong.service.response.get_header("Content-Type")
    local enc = kong.service.response.get_header("Content-Encoding")
    if not raw or raw == "" then
      kong.log.notice("skyflow-reidentify: no buffered response body; skipping"); return
    end

    -- Inflate gzip so the body is parseable; emit UNcompressed and drop the
    -- Content-Encoding header (identity is always acceptable).
    local body, was_encoded = raw, false
    if enc and enc ~= "" then
      if enc:lower():find("gzip", 1, true) and inflate_gzip then
        local iok, dec = pcall(inflate_gzip, raw)
        if not iok or not dec then
          kong.log.notice("skyflow-reidentify: gzip inflate failed; skipping"); return
        end
        body, was_encoded = dec, true
      else
        kong.log.notice("skyflow-reidentify: unsupported Content-Encoding '", enc, "'; skipping"); return
      end
    end

    local newbody
    if wants_json(conf, ct) then
      local doc = cjson.decode(body)
      if doc == nil then
        kong.log.notice("skyflow-reidentify: body not decodable JSON; skipping"); return
      end
      local spans = collect_spans(doc, effective_paths(conf))
      if #spans == 0 then return end
      for _, span in ipairs(spans) do
        local restored, rerr = skyflow_reidentify(conf, authz, span.text, deadline)
        if not restored then call_err = rerr; return end
        span.parent[span.key] = restored
      end
      newbody = cjson.encode(doc)
    else
      local restored, rerr = skyflow_reidentify(conf, authz, body, deadline)
      if not restored then call_err = rerr; return end
      newbody = restored
    end

    if newbody then
      kong.response.set_raw_body(newbody)
      if was_encoded then kong.response.clear_header("Content-Encoding") end
      kong.response.set_header("Content-Length", #newbody)
      kong.log.notice("skyflow-reidentify: restored response",
                      was_encoded and " (inflated gzip)" or "")
    end
  end)

  if (not ok) or call_err then
    kong.log.warn("skyflow-reidentify error; returning tokenized response",
                  (not ok) and (": pcall: " .. tostring(perr))
                            or (call_err and (": " .. call_err) or ""))
    if conf.on_error == "deny" then
      return kong.response.exit(502, { message = "response blocked: re-identify failed" })
    end
  end
end

return SkyflowReidentify
