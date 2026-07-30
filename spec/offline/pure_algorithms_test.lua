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

-- 2b. anthropic profile covers tool_result blocks (string + text-block forms)
local adoc = { messages = {
  { role = "user", content = "check the patient file" },
  { role = "assistant", content = { { type = "tool_use", id = "t1", name = "read", input = {} } } },
  { role = "user", content = { {
      type = "tool_result", tool_use_id = "t1",
      content = { { type = "text", text = "name: David Okafor" } },
  } } },
  { role = "user", content = { { type = "tool_result", tool_use_id = "t2", content = "plain string result" } } },
} }
local aconf = { profile = "anthropic", request_json_paths = {}, response_json_paths = {} }
local aspans = T.collect_spans(adoc, T.effective_paths(aconf, "request"))
local found = {}
for _, s in ipairs(aspans) do found[s.text] = true end
eq(found["name: David Okafor"], true, "anthropic profile reaches tool_result text blocks")
eq(found["plain string result"], true, "anthropic profile reaches string tool_results")
eq(found["check the patient file"], true, "anthropic profile still covers plain content")

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

-- 11. layered ctx assembly: nested JSON base + flat layers, later layers win
local base = { tenant = "acme", org = { id = "org_1", unit = "eng" }, pci = true, risk = 2 }
local ctx, key = T.build_ctx(base, {
  { ["org.unit"] = "payments", purpose = "agent-egress" },   -- static (dot-path nests)
  { ["caller.user"] = "alice", tenant = "spoofed" },          -- client headers
  { tenant = "acme", ["caller.route"] = "claude" },           -- trusted kong facts (last, win)
})
eq(ctx.org.id, "org_1", "build_ctx keeps nested base attr")
eq(ctx.org.unit, "payments", "build_ctx dot-path overrides nested base")
eq(ctx.caller.user, "alice", "build_ctx dot-path creates nested attrs")
eq(ctx.caller.route, "claude", "build_ctx merges multiple layers")
eq(ctx.tenant, "acme", "build_ctx later (trusted) layer wins over client layer")
eq(ctx.pci, true, "build_ctx preserves boolean base values")
eq(ctx.risk, 2, "build_ctx preserves numeric base values")
eq(base.org.unit, "eng", "build_ctx never mutates the shared base (deep copy)")
local _, key2 = T.build_ctx({ org = { unit = "payments", id = "org_1" }, tenant = "acme",
                              pci = true, risk = 2, purpose = "agent-egress",
                              caller = { user = "alice", route = "claude" } }, {})
eq(key, key2, "canonical key is insertion-order independent")
local _, key3 = T.build_ctx({ risk = "2" }, {})
local _, key4 = T.build_ctx({ risk = 2 }, {})
eq(key3 ~= key4, true, "canonical key distinguishes string vs number")
local nctx, nkey = T.build_ctx(nil, { nil, nil })
eq(nctx, nil, "build_ctx nil when no context configured")
eq(nkey, "", "build_ctx empty key when no context")
local ectx = T.build_ctx(nil, { { user = "" } })
eq(ectx, nil, "build_ctx ignores empty-string values")

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

-- 12b. thinking blocks must survive the SSE re-emit AS thinking blocks.
-- Collapsing them to text produced `text: ""`, which clients persist and
-- replay, and the API then rejects the next turn ("text content blocks must be
-- non-empty"). Extended thinking is on by default in some clients, so this
-- broke every multi-turn conversation.
local think = T.anthropic_message_to_sse({
  id = "msg_2", type = "message", role = "assistant", model = "m",
  content = {
    { type = "thinking", thinking = "let me consider", signature = "sig-abc" },
    { type = "text", text = "Hello Jane" },
    { type = "text", text = "" },              -- must be dropped, not emitted
  },
  stop_reason = "end_turn",
})
eq(think:find('"type":"thinking"', 1, true) ~= nil, true, "thinking block kept as thinking")
eq(think:find('"thinking_delta"', 1, true) ~= nil, true, "thinking text uses thinking_delta")
eq(think:find('"signature":"sig-abc"', 1, true) ~= nil, true, "thinking signature preserved")
eq(select(2, think:gsub('"type":"text_delta"', "")), 1, "exactly one text_delta (empty text dropped)")
eq(select(2, think:gsub("event: content_block_start", "")), 2, "2 blocks emitted, not 3")
eq(think:find('"text":""', 1, true) ~= nil, true, "block_start still opens text with empty string")
-- indexes must stay contiguous after dropping a block
eq(think:find('"index":0', 1, true) ~= nil and think:find('"index":1', 1, true) ~= nil, true,
   "indexes contiguous 0,1")
eq(think:find('"index":2', 1, true), nil, "no index 2 after dropping the empty block")

local redacted = T.anthropic_message_to_sse({
  type = "message", content = { { type = "redacted_thinking", data = "enc" } },
})
eq(redacted:find('"redacted_thinking"', 1, true) ~= nil, true, "redacted_thinking passed through")

-- 13. scope_from_roles: token-exchange body scope string
eq(T.scope_from_roles({ "r1", "r2" }), "role:r1 role:r2", "scope_from_roles two roles")
eq(T.scope_from_roles({ "only" }), "role:only", "scope_from_roles one role")
eq(T.scope_from_roles({}), nil, "scope_from_roles empty -> nil")
eq(T.scope_from_roles(nil), nil, "scope_from_roles nil -> nil")

-- 14. precheck_caller_token: which failures are the CALLER's (401) vs ours (502)
--
-- The harness stubs cjson.decode, so install a decoder good enough for the flat
-- claim sets below. handler.lua resolves cjson.decode at call time, so swapping
-- the field in place is visible to it.
package.loaded["cjson.safe"].decode = function(str)
  local out = {}
  -- "key":[ "a", "b" ]  -> array of strings
  for k, list in str:gmatch('"([%w_]+)"%s*:%s*%[([^%]]*)%]') do
    local arr = {}
    for v in list:gmatch('"([^"]*)"') do arr[#arr + 1] = v end
    out[k] = arr
  end
  for k, v in str:gmatch('"([%w_]+)"%s*:%s*"([^"]*)"') do out[k] = v end
  for k, v in str:gmatch('"([%w_]+)"%s*:%s*(%-?%d+%.?%d*)') do out[k] = tonumber(v) end
  return out
end

local ISS, AUD = "https://login.microsoftonline.com/t1/v2.0", "aud-guid"
local function jwt(claims_json)
  return T.b64url_encode('{"alg":"RS256"}') .. "." .. T.b64url_encode(claims_json) .. ".sig"
end
local function pc(claims_json, sts)
  return T.precheck_caller_token(jwt(claims_json), sts or
    { expected_issuer = ISS, expected_audience = AUD })
end

-- ngx.now() is stubbed to 0, so exp=100 is in the future and exp=-1 is past
local good = '{"iss":"' .. ISS .. '","aud":"' .. AUD .. '","sub":"u1","exp":100}'
local claims = pc(good)
eq(type(claims), "table", "precheck accepts a matching token")
eq(claims.sub, "u1", "precheck returns the claims")

local _, msg, kind = T.precheck_caller_token("not-a-jwt", { expected_issuer = ISS })
eq(kind, "identity", "non-JWT is the caller's problem")
eq(msg, "caller token is not a JWT", "non-JWT message")

local _, emsg, ekind = pc('{"iss":"' .. ISS .. '","aud":"' .. AUD .. '","exp":-1}')
eq(ekind, "identity", "expired token is the caller's problem")
eq(emsg:find("expired", 1, true) ~= nil, true, "expired message says so")
eq(emsg:find("sign in again", 1, true) ~= nil, true, "expired message says what to do")

local _, imsg, ikind = pc('{"iss":"https://evil/","aud":"' .. AUD .. '","exp":100}')
eq(ikind, "identity", "issuer mismatch is the caller's problem")
eq(imsg, "caller token issuer mismatch", "issuer mismatch message")

local _, amsg, akind2 = pc('{"iss":"' .. ISS .. '","aud":"other-app","exp":100}')
eq(akind2, "identity", "audience mismatch is the caller's problem")
eq(amsg, "caller token audience mismatch", "audience mismatch message")

-- Entra sends aud as a list in some configurations; membership must count
eq(type(pc('{"iss":"' .. ISS .. '","aud":["x","' .. AUD .. '"],"exp":100}')), "table",
   "audience inside a list is accepted")

-- an unconfigured check must not behave as "must be empty"
eq(type(T.precheck_caller_token(jwt('{"iss":"https://anything/","exp":100}'), {})), "table",
   "unconfigured issuer/audience checks are skipped")

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
os.exit(fails == 0 and 0 or 1)
