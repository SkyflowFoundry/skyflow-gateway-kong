-- In-process mock of the Skyflow Detect API for hermetic tests (docs/06 §6.2).
--
-- Two ways to use it:
--   1) As a PURE function in unit tests: `mock.handle(path, body, headers)`
--      returns `status, json_table` -- deterministic, no network.
--   2) Served over HTTP in integration tests via an OpenResty
--      `content_by_lua_block` (see `mock.server_block()` below) or
--      helpers.http_mock, then point the plugin at it with
--      `config.skyflow_base_url_override`.
--
-- Fault injection: send header `x-mock-fault` = timeout|500|401|429|garbage to
-- deterministically exercise client.lua's error branches.

local cjson = require "cjson.safe"

local _M = {}

-- Deterministic, reversible fixture mapping (value <-> token).
_M.fixtures = {
  ["Jane Doe"]            = { token = "NAME_aB3xQ",         entity = "NAME" },
  ["jane@acme.com"]       = { token = "EMAIL_ADDRESS_kp2",  entity = "EMAIL_ADDRESS" },
  ["123-45-6789"]         = { token = "SSN_0ykQWPA",        entity = "SSN" },
  ["4111111111111111"]    = { token = "CREDIT_CARD_N92QAVa",entity = "CREDIT_CARD" },
}

local function token_to_value()
  local rev = {}
  for value, m in pairs(_M.fixtures) do rev[m.token] = { value = value, entity = m.entity } end
  return rev
end

-- Replace every known fixture value in `text` with its token; collect entities.
local function deidentify(text)
  local processed, entities = text, {}
  for value, m in pairs(_M.fixtures) do
    if processed:find(value, 1, true) then
      processed = processed:gsub(value:gsub("([^%w])", "%%%1"), "[" .. m.token .. "]")
      entities[#entities + 1] = {
        token = m.token, value = value, entity = m.entity,
        scores = { [m.entity] = 0.99 },
      }
    end
  end
  return { processed_text = processed, entities = entities,
           word_count = select(2, text:gsub("%S+", "")), char_count = #text }
end

-- Replace every known token in `text` with its original value.
local function reidentify(text)
  local processed, rev = text, token_to_value()
  for token, info in pairs(rev) do
    processed = processed:gsub("%[" .. token .. "%]", info.value)
    processed = processed:gsub(token, info.value)
  end
  return { processed_text = processed, errors = {} }
end

-- Pure dispatch used by unit tests and the HTTP server block.
-- Returns status:int, body:table
function _M.handle(path, raw_body, headers)
  headers = headers or {}
  local fault = headers["x-mock-fault"] or headers["X-Mock-Fault"]
  if fault == "500" then return 500, { message = "mock 5xx" } end
  if fault == "401" then return 401, { message = "expired" } end
  if fault == "429" then return 429, { message = "rate limited" } end
  if fault == "garbage" then return 200, "<<<not-json>>>" end
  -- (timeout is simulated by the server block sleeping; n/a in pure mode)

  local body = cjson.decode(raw_body) or {}

  if path:find("/v1/detect/deidentify/string", 1, true) then
    return 200, deidentify(body.text or "")

  elseif path:find("/v1/detect/reidentify/string", 1, true) then
    return 200, reidentify(body.text or "")

  elseif path:find("/detokenize", 1, true) then
    local rev, records = token_to_value(), {}
    for _, p in ipairs(body.detokenizationParameters or {}) do
      local info = rev[p.token]
      records[#records + 1] = { token = p.token,
        value = info and info.value or nil, valueType = "STRING" }
    end
    return 200, { records = records }

  elseif path:find("/oauth/token", 1, true) or path:find("/auth/", 1, true) then
    return 200, { accessToken = "mock-access-token", tokenType = "Bearer", expiresIn = 3600 }
  end

  return 404, { message = "mock: unknown path " .. path }
end

-- OpenResty content handler body for an integration fixture server.
-- Embed inside a server block listening on a test port; the plugin's
-- skyflow_base_url_override should point here.
function _M.server_block()
  return [[
    content_by_lua_block {
      local mock = require "spec.skyflow-deidentify.helpers.mock_skyflow"
      ngx.req.read_body()
      local headers = ngx.req.get_headers()
      if (headers["x-mock-fault"] == "timeout") then ngx.sleep(30) end
      local status, body = mock.handle(ngx.var.uri, ngx.req.get_body_data() or "", headers)
      ngx.status = status
      ngx.header["Content-Type"] = "application/json"
      if type(body) == "table" then
        ngx.say(require("cjson").encode(body))
      else
        ngx.say(body)  -- garbage / non-JSON fault
      end
    }
  ]]
end

return _M
