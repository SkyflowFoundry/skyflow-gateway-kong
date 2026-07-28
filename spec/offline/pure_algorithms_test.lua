-- Offline validation of the pure algorithms in handler.lua (no Kong runtime).
package.loaded["resty.http"] = { new = function()
  return setmetatable({}, { __index = function() return function() end end })
end }
-- minimal deterministic JSON encoder (sorted keys) so SSE-emitter tests can
-- assert on real output; decode stays a stub (nothing under test needs it)
local function jenc(v)
  local t = type(v)
  if t == "string" then return '"' .. v:gsub('[\\"]', "\\%0"):gsub("\n", "\\n") .. '"' end
  if t == "number" or t == "boolean" then return tostring(v) end
  if t ~= "table" then return "null" end
  if #v > 0 then
    local parts = {}
    for _, x in ipairs(v) do parts[#parts + 1] = jenc(x) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = '"' .. tostring(k) .. '":' .. jenc(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end
package.loaded["cjson.safe"] = { encode = jenc, decode = function() return nil end }
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
local spans = T.collect_spans(doc, paths)
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

-- 6. sse_chunk: a content response becomes one chunk carrying the whole answer
local c1 = T.sse_chunk({ id = "x", created = 7, model = "m",
  choices = { { message = { role = "assistant", content = "Hi Jane" }, finish_reason = "stop" } } })
eq(c1.object, "chat.completion.chunk", "sse_chunk object type")
eq(c1.id, "x", "sse_chunk preserves id")
eq(c1.choices[1].index, 0, "sse_chunk choice index 0")
eq(c1.choices[1].delta.content, "Hi Jane", "sse_chunk carries content in delta")
eq(c1.choices[1].delta.role, "assistant", "sse_chunk carries role")
eq(c1.choices[1].finish_reason, "stop", "sse_chunk preserves finish_reason")

-- 7. sse_chunk: a tool_call response gets a streaming `index` on each tool_call
local c2 = T.sse_chunk({ id = "y", choices = { { message = {
  role = "assistant", content = nil,
  tool_calls = { { id = "call_1", type = "function", ["function"] = { name = "read", arguments = "{}" } },
                 { id = "call_2", type = "function", ["function"] = { name = "edit", arguments = "{}" } } },
}, finish_reason = "tool_calls" } } })
eq(c2.choices[1].delta.tool_calls[1].index, 0, "sse_chunk tool_call[1].index=0")
eq(c2.choices[1].delta.tool_calls[2].index, 1, "sse_chunk tool_call[2].index=1")
eq(c2.choices[1].delta.tool_calls[1]["function"].name, "read", "sse_chunk preserves tool name")
eq(c2.choices[1].finish_reason, "tool_calls", "sse_chunk preserves tool_calls finish_reason")

-- 8. sse_chunk: an absent message falls back to a valid empty assistant delta
local c3 = T.sse_chunk({ choices = {} })
eq(c3.choices[1].delta.role, "assistant", "sse_chunk default role")
eq(c3.choices[1].delta.content, "", "sse_chunk default empty content")
eq(c3.choices[1].finish_reason, "stop", "sse_chunk default finish_reason")

-- 9. base64url round-trip (RFC 4648 §5, unpadded) incl. binary + URL-unsafe bytes
eq(T.b64url_encode("any carnal pleasure."), "YW55IGNhcm5hbCBwbGVhc3VyZS4", "b64url known vector")
eq(T.b64url_encode("f"), "Zg", "b64url 1-byte (no padding)")
eq(T.b64url_encode("fo"), "Zm8", "b64url 2-byte")
eq(T.b64url_encode(string.char(0xfb, 0xff, 0xfe)), "-__-", "b64url uses -_ alphabet")
for _, s in ipairs({ "", "a", "ab", "abc", "abcd", '{"alg":"RS256","typ":"JWT"}',
                     string.char(0, 1, 2, 253, 254, 255) }) do
  eq(T.b64url_decode(T.b64url_encode(s)), s, "b64url round-trip len=" .. #s)
end
eq(T.b64url_decode("Zm8="), "fo", "b64url_decode tolerates padding")
eq(T.b64url_decode("+/"), string.char(0xfb), "b64url_decode accepts standard alphabet")
eq(T.b64url_decode("a"), nil, "b64url_decode rejects impossible length")
eq(T.b64url_decode("a!bc"), nil, "b64url_decode rejects bad chars")

-- 10. jwt_exp: reads exp straight out of a JWT payload; 0 on garbage
local payload = T.b64url_encode('{"iss":"x","exp":1785300000,"sub":"x"}')
eq(T.jwt_exp("eyJhbGciOiJSUzI1NiJ9." .. payload .. ".sig"), 1785300000, "jwt_exp extracts exp")
eq(T.jwt_exp("mock-access-token"), 0, "jwt_exp 0 for non-JWT")
eq(T.jwt_exp(nil), 0, "jwt_exp 0 for nil")
eq(T.jwt_exp("a.!!!.c"), 0, "jwt_exp 0 for undecodable payload")

-- 11. build_ctx: static + header merge, header wins, canonical cache key sorted
local hdrs = { ["X-Consumer-Username"] = "alice", ["X-Team"] = "sales" }
local get = function(name) return hdrs[name] end
local ctx, key = T.build_ctx({ tenant = "acme", user = "static-user" },
                             { user = "X-Consumer-Username", team = "X-Team", missing = "X-Nope" }, get)
eq(ctx.tenant, "acme", "build_ctx keeps static attr")
eq(ctx.user, "alice", "build_ctx header overrides static")
eq(ctx.team, "sales", "build_ctx adds header attr")
eq(ctx.missing, nil, "build_ctx skips absent header")
eq(key, "team=sales&tenant=acme&user=alice", "build_ctx canonical key sorted")
local nctx, nkey = T.build_ctx(nil, nil, get)
eq(nctx, nil, "build_ctx nil when no context configured")
eq(nkey, "", "build_ctx empty key when no context")
local sctx = T.build_ctx({ tenant = "acme" }, nil, nil)
eq(sctx.tenant, "acme", "build_ctx static-only works without header getter")

-- 12. Anthropic-native SSE re-emit: full event sequence, text + tool_use blocks
eq(T.is_anthropic_message({ type = "message", content = {} }), true, "is_anthropic_message true")
eq(T.is_anthropic_message({ choices = {} }), false, "is_anthropic_message false for openai shape")
local sse = T.anthropic_message_to_sse({
  id = "msg_1", type = "message", role = "assistant", model = "m",
  content = {
    { type = "text", text = "Hi Jane" },
    { type = "tool_use", id = "tu_1", name = "write", input = { path = "/tmp/x" } },
  },
  stop_reason = "tool_use", usage = { input_tokens = 5, output_tokens = 7 },
})
local n_events = select(2, sse:gsub("event: ", ""))
eq(n_events, 9, "anthropic sse: 9 events (start + 2x3 blocks + delta + stop)")
eq(sse:find("event: message_start\ndata: ", 1, true) ~= nil, true, "anthropic sse: message_start first")
eq(sse:find('"type":"text_delta"', 1, true) ~= nil, true, "anthropic sse: text_delta present")
eq(sse:find('"text":"Hi Jane"', 1, true) ~= nil, true, "anthropic sse: text carried")
eq(sse:find('"type":"input_json_delta"', 1, true) ~= nil, true, "anthropic sse: tool_use as input_json_delta")
eq(sse:find('\\"path\\":\\"/tmp/x\\"', 1, true) ~= nil, true, "anthropic sse: tool input serialized")
eq(sse:find('"name":"write"', 1, true) ~= nil, true, "anthropic sse: tool name in block_start")
eq(sse:find('"stop_reason":"tool_use"', 1, true) ~= nil, true, "anthropic sse: stop_reason in message_delta")
eq(sse:find("event: message_stop", 1, true) ~= nil, true, "anthropic sse: message_stop last")
eq(sse:find('"index":0', 1, true) ~= nil and sse:find('"index":1', 1, true) ~= nil, true,
   "anthropic sse: 0-based block indexes")

-- 13. scope_from_roles: token-exchange body scope string
eq(T.scope_from_roles({ "r1", "r2" }), "role:r1 role:r2", "scope_from_roles two roles")
eq(T.scope_from_roles({ "only" }), "role:only", "scope_from_roles one role")
eq(T.scope_from_roles({}), nil, "scope_from_roles empty -> nil")
eq(T.scope_from_roles(nil), nil, "scope_from_roles nil -> nil")

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
os.exit(fails == 0 and 0 or 1)
