-- kong.plugins.skyflow-deidentify.handler
--
-- Lifecycle orchestration for the Skyflow De-identify plugin.
-- This handler owns *sequencing* and PDK I/O only; Skyflow wire format lives in
-- client.lua/auth.lua, payload shape in body.lua, the request map in mapping.lua.
-- See docs/04-plugin-spec.md §4.4.
--
-- NOTE: reference skeleton. Functions marked TODO are described in the spec and
-- intended to be filled in during the implementation phases (docs/05).

local auth    = require "kong.plugins.skyflow-deidentify.auth"
local client  = require "kong.plugins.skyflow-deidentify.client"
local body    = require "kong.plugins.skyflow-deidentify.body"
local mapping = require "kong.plugins.skyflow-deidentify.mapping"

local kong = kong
local ngx  = ngx

local SkyflowDeidentify = {
  -- Run before AI Proxy (priority 770) so the upstream only ever sees tokens.
  -- For determinism also configure: ordering.before.access = [ai-proxy, ...].
  PRIORITY = 775,
  VERSION  = "0.1.0",
}

-- Centralized fail-closed/open posture. A privacy control must default to NOT
-- leaking raw PII upstream, so `deny` returns an error rather than forwarding.
local function deidentify_failure(conf, err)
  kong.log.err("skyflow de-identify failed: ", err)
  -- metrics/log detail recorded in log phase via ctx
  local ctx = kong.ctx.plugin
  ctx.posture = conf.on_skyflow_error
  if conf.on_skyflow_error == "deny" then
    return kong.response.exit(502, { message = "request blocked: de-identification unavailable" })
  end
  -- allow: fall through, forwarding the ORIGINAL body unchanged (logged/alerted)
end

-----------------------------------------------------------------------------
function SkyflowDeidentify:init_worker()
  -- Register metrics counters/histograms. No network here: workers may start
  -- before config is available. See docs/08 §8.3.
  -- TODO: metrics.init()
end

-----------------------------------------------------------------------------
-- 3.4+: called whenever the plugin iterator rebuilds. Best place to pre-warm
-- credentials and surface misconfig early (in a timer so startup isn't blocked).
function SkyflowDeidentify:configure(configs)
  if not configs then return end
  for _, conf in ipairs(configs) do
    ngx.timer.at(0, function()
      local ok, err = pcall(auth.prewarm, conf)
      if not ok then
        kong.log.warn("skyflow auth pre-warm failed (will retry lazily): ", err)
      end
    end)
  end
end

-----------------------------------------------------------------------------
function SkyflowDeidentify:access(conf)
  local ctx = kong.ctx.plugin
  ctx.t0 = ngx.now()

  -- 1. Cheap short-circuits: no body / wrong content-type / oversized.
  if not body.request_has_body() then
    return
  end

  -- 2. Read the client body (raw; falls back to buffered read if spilled).
  local raw, err = body.read_request(conf)
  if not raw then
    return body.on_parse_error(conf, err)   -- deny or skip per config
  end

  -- 3. Extract the text spans to de-identify for the configured profile.
  local spans, perr = body.extract_request(raw, conf)
  if not spans then
    return body.on_parse_error(conf, perr)
  end
  if #spans == 0 then
    return  -- nothing sensitive-shaped to process
  end

  -- 4. Resolve a (cached) Skyflow bearer token.
  local token, aerr = auth.get(conf)
  if not token then
    -- auth failures ALWAYS deny (never fall through) — see docs/07 SO5.
    kong.log.err("skyflow auth error: ", aerr)
    return kong.response.exit(502, { message = "request blocked: auth unavailable" })
  end

  -- 5. De-identify (batched per conf.deidentify.batch_mode; deadline-aware).
  local result, derr = client.deidentify(spans, conf, token)
  if not result then
    return deidentify_failure(conf, derr)
  end

  -- 6. Capture the token->value map for the response phase + log counts.
  mapping.put(ctx, result.entities)
  ctx.entities_by_type = result.counts

  -- 7. Rewrite the outbound body (unless dry-run).
  if not conf.dry_run then
    local newbody = body.replace_request(raw, spans, result, conf)
    kong.service.request.set_raw_body(newbody)
    kong.service.request.set_header("Content-Length", #newbody)
  end

  -- 8. If we will re-identify the response, buffer it now (unless reassembling
  --    incrementally). De-identify-only deployments impose NO buffering, so
  --    streaming works normally.
  if conf.reidentify.enabled and conf.reidentify.streaming ~= "reassemble" then
    kong.service.request.enable_buffering()
  end
end

-----------------------------------------------------------------------------
-- Only meaningful when reidentify.enabled = true (buffered proxy). Implementing
-- `response` is mutually exclusive with header_filter/body_filter in Kong.
function SkyflowDeidentify:response(conf)
  if not conf.reidentify.enabled then return end

  local status = kong.service.response.get_status()
  if not status or status < 200 or status >= 300 then return end
  if not body.response_is_targetable(conf) then return end

  local raw = kong.service.response.get_raw_body()
  if not raw or raw == "" then return end

  local spans, perr = body.extract_response(raw, conf)
  if not spans or #spans == 0 then
    if perr then kong.log.warn("skyflow response parse skipped: ", perr) end
    return
  end

  local ctx = kong.ctx.plugin
  local result, rerr = client.reidentify(spans, conf, ctx, auth.get(conf))
  if not result then
    kong.log.warn("skyflow re-identify failed: ", rerr)
    if conf.reidentify.on_error == "deny" then
      return kong.response.exit(502, { message = "response blocked: re-identification failed" })
    end
    return  -- return_tokenized: leave the (tokenized) response as-is
  end

  local newbody = body.replace_response(raw, spans, result, conf)
  kong.response.set_raw_body(newbody)
  kong.response.set_header("Content-Length", #newbody)
end

-----------------------------------------------------------------------------
function SkyflowDeidentify:log(conf)
  local ctx = kong.ctx.plugin
  if conf.log and conf.log.detections then
    -- Structured log + metrics. COUNTS AND TYPES ONLY — never values.
    kong.log.set_serialize_value("skyflow.entities_by_type", ctx.entities_by_type or {})
    kong.log.set_serialize_value("skyflow.posture", ctx.posture or "enforce")
  end
  -- TODO: metrics.emit(ctx)
end

return SkyflowDeidentify
