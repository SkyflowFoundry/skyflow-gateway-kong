-- kong.plugins.skyflow-deidentify.client
--
-- Thin Skyflow Detect REST client over lua-resty-http with a keepalive pool.
-- One function per operation: deidentify(), reidentify(), detokenize().
-- Owns timeouts, bounded retries (idempotent ops), deadline enforcement, and
-- normalization of Skyflow responses to a small result type. See docs/03
-- §3.3-3.5 and §3.8.
--
-- Reference skeleton: request/response shapes follow the documented Detect API;
-- paths flagged (confirm) in docs/03 must be validated against the tenant.

local http  = require "resty.http"
local cjson = require "cjson.safe"

local ngx = ngx
local _M  = {}

local function base_url(conf)
  if conf.skyflow_base_url_override and conf.skyflow_base_url_override ~= "" then
    return conf.skyflow_base_url_override
  end
  return "https://" .. conf.cluster_id .. ".vault.skyflowapis.com"
end

local function auth_headers(conf, token)
  local h = {
    ["Authorization"] = "Bearer " .. token,
    ["Content-Type"]  = "application/json",
  }
  if conf.account_id and conf.account_id ~= "" then
    h["X-SKYFLOW-ACCOUNT-ID"] = conf.account_id
  end
  return h
end

-- Classify a Skyflow HTTP outcome into { ok, status, data, err, retryable }.
local function classify(res, err)
  if not res then
    return { ok = false, err = "transport: " .. tostring(err), retryable = true }
  end
  local s = res.status
  if s == 200 then
    local data = cjson.decode(res.body)
    if not data then
      return { ok = false, status = s, err = "non-JSON body", retryable = false }
    end
    if data.errors and #data.errors > 0 then
      return { ok = false, status = s, data = data, err = "skyflow errors[]", retryable = false }
    end
    return { ok = true, status = s, data = data }
  elseif s == 401 then
    return { ok = false, status = s, err = "unauthorized", retryable = true }   -- one refresh+retry
  elseif s == 403 then
    return { ok = false, status = s, err = "forbidden (grant Detect permission)", retryable = false }
  elseif s == 429 or s >= 500 then
    return { ok = false, status = s, err = "skyflow status " .. s, retryable = true }
  end
  return { ok = false, status = s, err = "skyflow status " .. s, retryable = false }
end

-- POST JSON with deadline-aware bounded retries for retryable failures.
-- `deadline` is an ngx.now() timestamp; `on_401` optionally refreshes the token.
local function post_json(conf, token, path, payload, deadline, on_401)
  local url = base_url(conf) .. path
  local attempts = (conf.retries or 0) + 1
  local last

  for i = 1, attempts do
    if ngx.now() >= deadline then
      return { ok = false, err = "deadline exceeded", retryable = false }
    end
    local httpc = http.new()
    httpc:set_timeout(conf.timeout_ms)
    local res, err = httpc:request_uri(url, {
      method = "POST",
      headers = auth_headers(conf, token),
      body = cjson.encode(payload),
      ssl_verify = true,
      keepalive_timeout = conf.keepalive_idle_ms,
      keepalive_pool = conf.keepalive_pool_size,
    })
    last = classify(res, err)
    if last.ok then return last end

    -- one forced token refresh on 401, then retry
    if last.status == 401 and on_401 and i < attempts then
      local newtok = on_401()
      if newtok then token = newtok end
    elseif not last.retryable then
      return last
    end
    -- (bounded) backoff before the next attempt could go here
  end
  return last
end

-- De-identify a list of spans -> { entities = {token->{value,entity}},
-- counts = {entity->n}, processed = {span_id->text} }.
-- Honors conf.deidentify.batch_mode (per_span concurrent vs joined).
function _M.deidentify(spans, conf, token)
  local deadline = ngx.now() + (conf.deadline_ms / 1000)
  local d = conf.deidentify

  local function one(text)
    local payload = {
      text = text,
      vault_id = conf.vault_id,
      entities = (#d.entities > 0) and d.entities or nil,
      token_type = { default = d.token_format },
      allow_regex_list = d.allow_regex,
      restrict_regex_list = d.restrict_regex,
    }
    if d.shift_dates and d.shift_dates.enabled then
      payload.transformations = { shift_dates = {
        min_days = d.shift_dates.min_days, max_days = d.shift_dates.max_days,
        entities = d.shift_dates.entities } }
    end
    return post_json(conf, token, "/v1/detect/deidentify/string", payload, deadline)
  end

  -- TODO(impl): per_span concurrency via ngx.thread.spawn bounded by
  -- conf.max_concurrency; joined mode via sentinel join/split. Aggregate the
  -- per-span results into entities/counts/processed. Map errors to nil + err.
  local _ = one  -- placeholder to keep `one` referenced in the skeleton
  return nil, "not implemented (reference skeleton)"
end

-- Re-identify response spans using the request mapping + entity treatment.
-- Dispatches on conf.reidentify.strategy.
function _M.reidentify(spans, conf, ctx, token)
  local deadline = ngx.now() + (conf.deadline_ms / 1000)
  local strategy = conf.reidentify.strategy

  if strategy == "mapping_only" then
    -- No Skyflow call: substitute tokens present in ctx.mapping. See mapping.lua.
    return nil, "not implemented (reference skeleton: mapping_only)"
  elseif strategy == "detokenize" then
    -- POST /v1/vaults/{vault_id}/detokenize with detokenizationParameters[].
    local _ = deadline
    return nil, "not implemented (reference skeleton: detokenize)"
  else -- reidentify_text
    -- POST /v1/detect/reidentify/string (confirm path) with
    -- redacted/masked/plain_text entity lists derived from entity_treatment.
    return nil, "not implemented (reference skeleton: reidentify_text)"
  end
end

return _M
