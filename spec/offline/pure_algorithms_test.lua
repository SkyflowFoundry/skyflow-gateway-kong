-- Offline validation of the pure algorithms in handler.lua (no Kong runtime).
package.loaded["resty.http"] = { new = function()
  return setmetatable({}, { __index = function() return function() end end })
end }
package.loaded["cjson.safe"] = { encode = function() return "" end, decode = function() return nil end }
_G.kong = { log = { err=function() end, warn=function() end, set_serialize_value=function() end },
  request = {}, response = {}, service = { request = {}, response = {} }, ctx = { plugin = {} } }
_G.ngx = { now = function() return 0 end }

local M = dofile("plugin/kong/plugins/skyflow-deidentify/handler.lua")
local T = M._test
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL: "..msg.." got="..tostring(a)) else print("ok: "..msg) end end

-- 1. parse_path
local toks = T.parse_path("$.messages[*].content[*].text")
eq(table.concat(toks, "|"), "messages|[*]|content|[*]|text", "parse_path nested wildcard")
eq(table.concat(T.parse_path("$.params.arguments.*"), "|"), "params|arguments|*", "parse_path any-key")
eq(table.concat(T.parse_path("$.choices[0].text"), "|"), "choices|[0]|text", "parse_path index")

-- 2. collect_spans over openai-shaped doc (string + array content forms)
local doc = { messages = {
    { role = "user", content = "Email Jane Doe" },
    { role = "user", content = { { type = "text", text = "card 4111" } } },
  }, prompt = "hi" }
local conf = { profile = "openai", request_json_paths = {}, response_json_paths = {} }
local paths = T.effective_paths(conf, "request")
local spans = T.collect_spans(doc, paths, 64)
eq(#spans, 3, "collect_spans found 3 string leaves")
-- replace and confirm mutation
for _, s in ipairs(spans) do s.parent[s.key] = "X" end
eq(doc.messages[1].content, "X", "replace string content")
eq(doc.messages[2].content[1].text, "X", "replace array-form text")
eq(doc.prompt, "X", "replace prompt")

-- 3. mask
eq(T.mask("4111111111111111"), "************1111", "mask keeps last 4")
eq(T.mask("abc"), "***", "mask short")

-- 4. reidentify_string with treatments
local by_token = {
  NAME_a = { value = "Jane", entity = "NAME" },
  SSN_b  = { value = "123-45-6789", entity = "SSN" },
  CC_c   = { value = "4111111111111111", entity = "CREDIT_CARD" },
}
local treatment = { CREDIT_CARD = "masked", SSN = "redacted" }
local fn = function(e) return treatment[e] or "plain_text" end
local out = T.reidentify_string("Hi [NAME_a], SSN [SSN_b], card [CC_c].", by_token, fn)
eq(out, "Hi Jane, SSN [SSN_b], card ************1111.", "reidentify honors treatments")

-- 5. generic override replaces defaults
local g = T.effective_paths({ profile = "generic", request_json_paths = { "$.x" }, response_json_paths = {} }, "request")
eq(g[1], "$.x", "generic uses override")
eq(#g, 1, "generic override count")

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
os.exit(fails == 0 and 0 or 1)
