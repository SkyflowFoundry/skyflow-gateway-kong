-- kong.plugins.skyflow-deidentify.body
--
-- Payload model: given a profile (openai/anthropic/mcp/generic) + JSONPath
-- overrides, extract the text spans that carry user content and write processed
-- text back into the same spans. Knows payload shape only -- not Skyflow, not
-- Kong I/O beyond reading/replacing bodies. See docs/04 §4.5.
--
-- A span is { id = <stable id>, path = <locator>, text = <string> }.
-- `replace_*` is location-exact and order-independent.

local cjson = require "cjson.safe"
local kong  = kong

local _M = {}

-- Built-in span selectors per profile (request / response). The selector
-- grammar is a small JSONPath subset: `$`, `.key`, `[*]`, `[n]`, and
-- string-leaf recursion under a node. See module notes below.
local PROFILES = {
  openai = {
    request  = { "$.messages[*].content", "$.input", "$.prompt" },
    response = { "$.choices[*].message.content", "$.choices[*].text" },
  },
  anthropic = {
    request  = { "$.messages[*].content[*].text", "$.system" },
    response = { "$.content[*].text" },
  },
  mcp = {
    request  = { "$.params.arguments.*", "$.params.messages[*].content" },
    response = { "$.result.content[*].text", "$.result.*" },
  },
  generic = { request = {}, response = {} },  -- driven by config paths
}

-- Resolve the effective selector list for a phase.
local function selectors(conf, phase)
  local base = PROFILES[conf.profile][phase] or {}
  local override = (phase == "request") and conf.request_json_paths or conf.response_json_paths
  if override and #override > 0 then
    if conf.profile == "generic" then return override end
    -- non-generic profiles: union profile defaults with explicit overrides
    local out = {}
    for _, s in ipairs(base) do out[#out + 1] = s end
    for _, s in ipairs(override) do out[#out + 1] = s end
    return out
  end
  return base
end

-- Does the current request plausibly carry a body we should inspect?
function _M.request_has_body()
  local m = kong.request.get_method()
  return m == "POST" or m == "PUT" or m == "PATCH"
end

-- Sniff whether we should treat the body as JSON or opaque text.
local function is_json(conf)
  if conf.content_type == "json" then return true end
  if conf.content_type == "text" then return false end
  local ct = kong.request.get_header("Content-Type") or ""
  return ct:find("application/json", 1, true) ~= nil
       or ct:find("+json", 1, true) ~= nil
end

-- Read the raw request body, honoring max_body_size.
function _M.read_request(conf)
  local raw = kong.request.get_raw_body()
  if raw == nil then
    -- Kong may have buffered the body to disk if it exceeded the in-memory
    -- buffer. TODO(impl): read via the buffered file when get_raw_body() is nil.
    return nil, "request body unavailable (buffered to disk?)"
  end
  if #raw > conf.max_body_size then
    return nil, "request body exceeds max_body_size"
  end
  return raw
end

-- Posture for parse failures (deny -> 502, skip -> forward unchanged).
function _M.on_parse_error(conf, err)
  kong.log.warn("skyflow body parse: ", err)
  if conf.on_parse_error == "deny" then
    return kong.response.exit(422, { message = "request blocked: unparseable body" })
  end
  -- skip: return nothing; handler forwards the original body
end

-- Extract spans from the request body for the active profile.
-- Returns spans[] (possibly empty) or nil, err on hard parse failure.
function _M.extract_request(raw, conf)
  if not is_json(conf) then
    return { { id = "whole", path = "$", text = raw } }
  end
  local doc = cjson.decode(raw)
  if doc == nil then return nil, "invalid JSON" end
  -- TODO(impl): walk `selectors(conf, "request")` over `doc` using the JSONPath
  -- subset; collect string leaves into spans capped at conf.max_spans. Keep the
  -- decoded doc on the span set so replace_request can re-encode in one pass.
  local _ = selectors(conf, "request")
  return {}  -- reference skeleton
end

-- Write processed text back into the request and return the new raw body.
function _M.replace_request(raw, spans, result, conf)
  -- TODO(impl): for JSON, set each span's location to result.processed[span.id]
  -- in the decoded doc and cjson.encode once; for text, return processed whole.
  return raw  -- reference skeleton (no-op)
end

-- Response-side equivalents -------------------------------------------------

function _M.response_is_targetable(conf)
  local ct = kong.service.response.get_header("Content-Type") or ""
  if conf.content_type == "text" then return true end
  return ct:find("application/json", 1, true) ~= nil or ct:find("+json", 1, true) ~= nil
       or ct:find("text/event-stream", 1, true) ~= nil  -- SSE (buffer mode)
end

function _M.extract_response(raw, conf)
  -- TODO(impl): mirror extract_request using selectors(conf, "response").
  local _ = selectors(conf, "response")
  return {}, nil
end

function _M.replace_response(raw, spans, result, conf)
  return raw  -- reference skeleton (no-op)
end

return _M
