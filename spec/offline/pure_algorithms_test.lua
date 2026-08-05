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
-- The stub keeps the deterministic encoder (SSE tests assert on exact output)
-- and a nil decoder (nothing under test needs it), but it MUST expose `new`,
-- because handler.lua builds its body codec via `cjson.new()`. Without it,
-- body_json silently fell back to this stub and the handler's real codec was
-- unobservable -- which is how a test written for the `tools: [] -> {}` bug
-- passed with the bug reinstated.
local real_cjson = select(2, pcall(require, "cjson.safe"))
package.loaded["cjson.safe"] = {
  encode = jenc,
  decode = function() return nil end,
  new = (type(real_cjson) == "table" and real_cjson.new) or nil,
  array_mt = (type(real_cjson) == "table" and real_cjson.array_mt) or nil,
  null = (type(real_cjson) == "table" and real_cjson.null) or nil,
}
_G.kong = { log = { err=function() end, warn=function() end, set_serialize_value=function() end },
  request = {}, response = {}, service = { request = {}, response = {} }, ctx = { plugin = {} } }
_G.ngx = { now = function() return 0 end }

local M = dofile("plugin/kong/plugins/skyflow-ai-data-control/handler.lua")
local T = M._test

-- Config moved into three top-level records (skyflow / targeting / operations).
-- These cases assert path and span behaviour, not config shape, so rather than
-- restate every literal they are written flat and nested here on the way in.
local function as_conf(c)
  if c.skyflow or c.operations then return c end
  return {
    skyflow = {
      vault_configuration = {
        vault_id = c.vault_id, account_id = c.account_id, vault_url = c.vault_url,
      },
      deidentify = c.deidentify, reidentify = c.reidentify,
    },
    targeting = {
      content_type        = c.content_type,
      request_json_paths  = c.request_json_paths,
      response_json_paths = c.response_json_paths,
    },
    operations = { limits = {}, on_error = {} },
  }
end

-- effective_paths takes (phase, formats) now: there are no operator path
-- overrides, so the conf these cases used to pass is no longer read.
local function EP3(_conf, phase, formats) return T.effective_paths(phase, formats) end

-- `profile` was removed from the config: the wire format is detected from the body.
-- These cases were written against the old field, and what they assert (which paths
-- a given format contributes) is unchanged, so this shim maps the old name onto the
-- new format-list argument. `generic` becomes the empty list -- "no shape recognised".
local function EP(conf, phase)
  local fmts = {}
  if conf.profile and conf.profile ~= "generic" then fmts = { conf.profile } end
  return EP3(conf, phase, fmts)
end
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
local paths = EP(conf, "request")
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
local aspans = T.collect_spans(adoc, EP(aconf, "request"))
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


-- 5. An unrecognised shape yields NO paths, and there is no override to supply
-- them: the supported formats are OpenAI, Anthropic and MCP, so anything else is a
-- misrouted request rather than a config gap. The access phase turns this into a
-- 422 rather than scanning nothing and reporting success.
eq(#T.effective_paths("request", {}), 0, "no detected format means nothing to scan")

-- 5b. The `generic` profile has NO built-in paths on either leg, so it is the one
-- profile that can be configured to do nothing while reporting success. Both legs
-- must be guarded, and the RESPONSE leg was not: zero response spans is
-- indistinguishable from "the response had no text", so it took the benign branch
-- and handed the client vault tokens forever, silently.
eq(#EP({ profile = "generic", request_json_paths = { "$.x" },
                        response_json_paths = {} }, "response"), 0,
   "generic has no default response paths -- which is why the guard is needed")
eq(#EP({ profile = "anthropic", request_json_paths = {},
                        response_json_paths = {} }, "response"), 1,
   "a named profile does have one, so the guard must not fire for it")

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

-- 11. Anthropic-native SSE re-emit: full event sequence, text + tool_use blocks
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
-- Matched loosely on purpose. Tool inputs are serialized by the handler's own
-- body codec (real cjson), not by this file's stub encoder, and the two differ in
-- ways that are irrelevant to the behaviour under test: key order is unspecified,
-- and real cjson escapes forward slashes (`"\/tmp\/x"`, valid JSON, decodes back
-- to `/tmp/x`). The old exact-string assertion was pinned to the stub, so it
-- broke the moment the test started exercising the production codec.
eq(sse:find('path', 1, true) ~= nil and sse:find('tmp', 1, true) ~= nil, true,
   "anthropic sse: tool input serialized")
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

-- 12. precheck_caller_token: which failures are the CALLER's (401) vs ours (502)
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
eq(type(pc('{"iss":"' .. ISS .. '","aud":["x","' .. AUD .. '"],"exp":100,"sub":"u1"}')), "table",
   "audience inside a list is accepted")

-- an unconfigured check must not behave as "must be empty"
eq(type(T.precheck_caller_token(jwt('{"iss":"https://anything/","exp":100,"sub":"u1"}'), {})), "table",
   "unconfigured issuer/audience checks are skipped")

-- A token with no subject is refused: the STS bearer cache is keyed on the
-- subject, so a placeholder default collapsed every subject-less caller into one
-- slot and handed caller B the bearer minted from caller A's identity.
local _, sub_err, sub_kind = T.precheck_caller_token(jwt('{"iss":"x","exp":100}'), {})
eq(sub_kind, "identity", "a subject-less token is an identity error")
eq(tostring(sub_err):find("no subject", 1, true) ~= nil, true,
   "and the message says why")

-- 13. inject_token_preamble: every system-prompt shape the profiles use.
-- The model must be told what [NAME_a1b2c3] IS, or it editorialises about
-- redaction instead of using the placeholder the gateway can resolve.
local PRE = "PREAMBLE"

local d1 = { messages = {} }
T.inject_token_preamble(d1, PRE, { "anthropic" })
eq(d1.system, PRE, "anthropic: absent system -> preamble becomes it")

local d2 = { system = "you are helpful", messages = {} }
T.inject_token_preamble(d2, PRE, { "anthropic" })
eq(d2.system, PRE .. "\n\nyou are helpful", "anthropic: string system -> prepended")

local d3 = { system = { { type = "text", text = "caller block" } }, messages = {} }
T.inject_token_preamble(d3, PRE, { "anthropic" })
eq(#d3.system, 2, "anthropic: block array gains one block")
eq(d3.system[1].text, PRE, "anthropic: preamble is FIRST")
eq(d3.system[2].text, "caller block", "anthropic: caller block preserved after it")

local d4 = { messages = { { role = "user", content = "hi" } } }
T.inject_token_preamble(d4, PRE, { "openai" })
eq(d4.messages[1].role, "system", "openai: system message inserted at the front")
eq(d4.messages[1].content, PRE, "openai: carries the preamble")
eq(d4.messages[2].role, "user", "openai: user message still second")

local d5 = { messages = { { role = "system", content = "be terse" },
                          { role = "user", content = "hi" } } }
T.inject_token_preamble(d5, PRE, { "openai" })
eq(#d5.messages, 2, "openai: existing system message is NOT duplicated")
eq(d5.messages[1].content, PRE .. "\n\nbe terse", "openai: prepended to the existing system")

-- the instruction that keeps re-identification working
eq(T.DEFAULT_TOKEN_PREAMBLE:find("square brackets", 1, true) ~= nil, true,
   "default preamble tells the model to keep the brackets")
eq(T.DEFAULT_TOKEN_PREAMBLE:lower():find("describe the material as redacted", 1, true) ~= nil, true,
   "default preamble forbids characterising the material as redacted")

-- The example suffixes must NOT be token-shaped: a plausible-looking example
-- rides on every request and, if echoed, sends re-identification after a token
-- that was never issued. `%w` covers the a1b2c3 form the old preamble used.
eq(T.DEFAULT_TOKEN_PREAMBLE:find("%[NAME_%l%d%l%d%l%d%]") == nil, true,
   "no lowercase-alphanumeric (token-shaped) example suffix")
eq(T.DEFAULT_TOKEN_PREAMBLE:find("[NAME_EXAMPLE]", 1, true) ~= nil, true,
   "examples use the literal word EXAMPLE, which cannot collide with a real suffix")
eq(T.DEFAULT_TOKEN_PREAMBLE:lower():find("add caveats about it", 1, true) ~= nil, true,
   "default preamble forbids privacy disclaimers")

-- 14. Empty arrays must round-trip as arrays, THROUGH THE HANDLER'S OWN CODEC.
-- Claude Desktop sends `tools: []` on its title-generation call; Lua has one
-- table type, so a plain cjson decode/encode turned that into `tools: {}` and
-- Anthropic answered 400 "tools: Input should be a valid array" on EVERY such
-- request.
--
-- The previous version of this section asserted on the cjson LIBRARY instead of
-- on the handler, and therefore passed with the bug reinstated -- verified by
-- mutation. These assertions go through T.decode_body / T.encode_body, the exact
-- functions the request and response bodies traverse, so reverting the fix in
-- handler.lua fails here.
if T.decode_body and T.encode_body then
  local body = '{"model":"m","tools":[],"messages":[{"role":"user","content":"hi"}]}'
  local out = T.encode_body(T.decode_body(body))
  eq(out ~= nil, true, "handler codec decodes and re-encodes a request body")
  eq(out:find('"tools":[]', 1, true) ~= nil, true,
     "handler codec PRESERVES an empty array (the 400 that broke title generation)")
  eq(out:find('"tools":{}', 1, true) == nil, true,
     "handler codec never emits {} for an empty array")

  local nested = T.encode_body(T.decode_body(
    '{"tools":[{"input_schema":{"properties":{},"required":[]}}]}'))
  eq(nested:find('"required":[]', 1, true) ~= nil, true, "nested empty array survives")
  eq(nested:find('"properties":{}', 1, true) ~= nil, true,
     "an empty OBJECT still encodes as an object, not an array")

  -- a tool_use input carrying an empty array: the second site of the same bug,
  -- on the SSE re-emit path
  local ti = T.encode_body(T.decode_body('{"paths":[],"query":"x"}'))
  eq(ti:find('"paths":[]', 1, true) ~= nil, true,
     "tool_use input keeps its empty array on the re-emit path")
else
  fails = fails + 1
  print("FAIL: handler codec not exported (decode_body/encode_body) -- cannot verify the tools:[] fix")
end

-- 15. tool_policy: which tool calls get real values back. The bug this fixes:
-- with one global `tokenized` setting, the model's Edit call carried
-- [NAME_X2A0iim] as its `old_string` and the LOCAL editor wrote that token into
-- the user's real file. The destination of the call decides the policy, and the
-- tool name is what names the destination.
local function tconf(default, by)
  return as_conf({ reidentify = { tool_inputs = default, tool_inputs_by_tool = by } })
end

local DESKTOP = {
  ["Read"] = "plain_text", ["Edit"] = "plain_text", ["Write"] = "plain_text",
  ["mcp__workspace__*"] = "plain_text",
  ["mcp__workspace__web_fetch"] = "tokenized",   -- narrower rule, egresses
  ["WebSearch"] = "tokenized",
}
local c = tconf("tokenized", DESKTOP)

eq(T.tool_policy(c, "Edit"), "plain_text", "local editor gets real values (the file-corruption bug)")
eq(T.tool_policy(c, "WebSearch"), "tokenized", "web search stays tokenized")
eq(T.tool_policy(c, "mcp__workspace__bash"), "plain_text", "prefix rule covers a local MCP server")
eq(T.tool_policy(c, "mcp__workspace__web_fetch"), "tokenized",
   "exact match beats the prefix rule that contains it")
eq(T.tool_policy(c, "mcp__slack__send_message"), "tokenized",
   "an unlisted MCP server falls back to the default")

-- longest prefix wins, so a broad rule can be narrowed by a longer one
local nested = tconf("tokenized", { ["mcp__*"] = "tokenized",
                                    ["mcp__workspace__*"] = "plain_text" })
eq(T.tool_policy(nested, "mcp__workspace__bash"), "plain_text", "longest prefix wins")
eq(T.tool_policy(nested, "mcp__other__thing"), "tokenized", "shorter prefix still applies elsewhere")

-- the fallback must survive every degenerate shape, since this runs per tool call
eq(T.tool_policy(tconf("tokenized", {}), "Edit"), "tokenized", "empty map -> default")
eq(T.tool_policy(tconf("plain_text", {}), "Edit"), "plain_text", "default can be plain_text")
eq(T.tool_policy(tconf(nil, {}), "Edit"), "tokenized", "absent default -> tokenized (fail safe)")
eq(T.tool_policy(tconf("tokenized", nil), "Edit"), "tokenized", "absent map -> default")
eq(T.tool_policy(c, nil), "tokenized", "nil tool name -> default, no crash")
eq(T.tool_policy(c, ""), "tokenized", "empty tool name -> default")

-- a `*` in a NAME must not be treated as a wildcard from the other direction
eq(T.tool_policy(tconf("tokenized", { ["a-b.c"] = "plain_text" }), "a-b.c"), "plain_text",
   "regex-magic characters in a key are matched literally")

-- 16. Two coverage gaps found by diffing live egress against what we tokenize.
-- Both were invisible in testing because the SHAPES only occur in real client
-- traffic: Claude Desktop sends `system` as a block array, and a replayed
-- tool_use only exists from the second turn of a tool-using conversation on.
local gconf = { profile = "anthropic", request_json_paths = {}, response_json_paths = {} }
local gpaths = EP(gconf, "request")
local function texts(doc)
  local out = {}
  for _, sp in ipairs(T.collect_spans(doc, gpaths)) do out[sp.text] = true end
  return out
end

-- `$.system` alone matches only the scalar form; Desktop uses the array form,
-- so the whole system prompt was going upstream unscanned.
eq(texts({ system = "plain SECRET" })["plain SECRET"], true, "system as a string is covered")
eq(texts({ system = { { type = "text", text = "block SECRET" } } })["block SECRET"], true,
   "system as a BLOCK ARRAY is covered (Claude Desktop's shape)")

-- A restored tool input returns on every later turn as replayed history.
local replay = { messages = { { role = "assistant", content = {
  { type = "tool_use", id = "t1", name = "mcp__salesforce__soql",
    input = { soql = "WHERE Name='Johnathan Smith'" } } } } } }
eq(texts(replay)["WHERE Name='Johnathan Smith'"], true, "replayed tool_use.input is covered")

-- `**` must reach ARBITRARY depth: a tool's input schema is caller-defined, so
-- single-level `*` would silently miss anything nested.
local deep = { messages = { { role = "assistant", content = {
  { type = "tool_use", id = "t2", name = "q",
    input = { filter = { contact = { name = "DEEP_SECRET" } }, top = "TOP_SECRET" } } } } } }
local dt = texts(deep)
eq(dt["DEEP_SECRET"], true, "** reaches a 3-level-nested string")
eq(dt["TOP_SECRET"], true, "** still reaches the shallow sibling")

-- `**` collects strings only, and must not crash on non-string leaves
local mixed = { messages = { { role = "assistant", content = {
  { type = "tool_use", id = "t3", name = "q",
    input = { n = 42, ok = true, s = "STR", list = { "A", "B" } } } } } } }
local mt = texts(mixed)
eq(mt["STR"] and mt["A"] and mt["B"], true, "** collects strings incl. inside arrays")
eq(mt[42], nil, "** ignores numbers")

-- terminal-only, and cycle/depth safe on hostile nesting
local nest = { a = "X" }
local cur = nest
for _ = 1, 40 do cur.next = { a = "Y" }; cur = cur.next end
local okdeep = pcall(function() T.collect_spans({ messages = { { role = "assistant",
  content = { { type = "tool_use", input = nest } } } } }, gpaths) end)
eq(okdeep, true, "** survives nesting deeper than the depth guard")

-- 17. classify_client_error: the 404 that destroyed a finished response.
-- On 2026-07-29 a model reformatted a token we had issued (bulleting `[NAME_x]`
-- into `- x`); Skyflow's reidentify answered 404 "Detokenization failed. Token X
-- is invalid."; the generic 4xx branch called it a client error; on_error=deny
-- turned that into a 502; and a complete 289-token answer was thrown away.
-- An unmatched token is MODEL behaviour, not a fault, and the text is still
-- tokenized -- therefore still safe to deliver.
local UNMATCHED = 'Detokenization failed. Token Ot1Tsdz is invalid. Specify a valid token.'

local _, k = T.classify_client_error(404, UNMATCHED)
eq(k, "unmatched_token", "404 + 'Detokenization failed' is an unmatched token, not a failure")
local _, k2 = T.classify_client_error(404, '{"error":"Token abc is invalid"}')
eq(k2, "unmatched_token", "the 'is invalid' marker also identifies an unmatched token")

-- The marker is load-bearing. A bare 404 means a wrong base_url or vault_id --
-- being lenient there would silently forward tokenized text on a misconfigured
-- gateway, which is exactly the case that must fail closed.
local _, k3 = T.classify_client_error(404, "not found")
eq(k3, "client_error", "a 404 WITHOUT the marker stays a hard client error (misconfigured URL)")
local _, k4 = T.classify_client_error(404, nil)
eq(k4, "client_error", "a 404 with no body stays a hard client error")

-- everything else must keep failing closed
local m5, k5 = T.classify_client_error(403, "denied")
eq(k5, "forbidden", "403 is its own kind")
eq(m5:find("permission", 1, true) ~= nil, true, "403 message names the missing permission")
eq(select(2, T.classify_client_error(400, UNMATCHED)), "client_error",
   "the marker does NOT excuse a 400 -- only a 404 can be an unmatched token")
eq(select(2, T.classify_client_error(401, "nope")), "client_error", "401 stays a client error")
eq(select(2, T.classify_client_error(422, "bad payload")), "client_error", "422 stays a client error")

-- 18. run_waves: concurrent span de-identification. Untested code that decides
-- whether a de-identification FAILURE is noticed is the worst kind to have, and
-- the offline harness has no ngx.thread, so the wave runner takes injected
-- spawn/wait functions and is exercised both ways here.
local function fake_threads()
  -- Cooperative fake: spawn runs immediately and boxes the result, wait unboxes.
  -- Enough to prove the aggregation and error contracts; real overlap is an
  -- OpenResty property, not a logic one.
  return function(fn, arg) return { pcall(fn, arg) } end,
         function(box) return box[1], box[2], box[3] end
end
local spawn, wait = fake_threads()

-- every item is processed, in order, and results are collected
local seen = {}
local res, err = T.run_waves({1,2,3,4,5}, 2, function(n)
  seen[#seen+1] = n; return n * 10
end, spawn, wait)
eq(err, nil, "run_waves: no error on the happy path")
eq(#res, 5, "run_waves: every item produced a result")
eq(table.concat(seen, ","), "1,2,3,4,5", "run_waves: every item was processed")

-- THE contract that matters: a failure is never dropped
local r2, e2 = T.run_waves({1,2,3}, 3, function(n)
  if n == 2 then return nil, "detect exploded on 2" end
  return n
end, spawn, wait)
eq(e2, "detect exploded on 2", "run_waves: an item failure is reported, not swallowed")

-- a crash (thrown error) must SURFACE as an error rather than unwind. Tested on
-- BOTH branches: with width>1 (concurrent) and width==1 (sequential), because
-- the sequential branch originally lacked the pcall and a throw escaped the
-- whole request instead of being reported.
local _, e3 = T.run_waves({1,2}, 2, function() error("boom") end, spawn, wait)
eq(type(e3) == "string" and e3:find("crashed", 1, true) ~= nil, true,
   "run_waves: a thrown error surfaces as an error (concurrent branch)")
local _, e3b = T.run_waves({1}, 1, function() error("boom") end, spawn, wait)
eq(type(e3b) == "string" and e3b:find("crashed", 1, true) ~= nil, true,
   "run_waves: a thrown error surfaces as an error (sequential branch)")
local _, e3c = T.run_waves({1,2,3}, 8, function() error("boom") end, nil, nil)
eq(type(e3c) == "string" and e3c:find("crashed", 1, true) ~= nil, true,
   "run_waves: a throw in the no-thread fallback is reported, not propagated")

-- a failure with no message still fails closed rather than reporting success
local _, e4 = T.run_waves({1}, 1, function() return nil end, spawn, wait)
eq(e4, "unknown worker failure", "run_waves: nil-with-no-message still fails")

-- and it must stop early rather than keep spending Detect calls after a failure
local calls = 0
T.run_waves({1,2,3,4,5,6}, 2, function(n)
  calls = calls + 1
  if n == 1 then return nil, "fail fast" end
  return n
end, spawn, wait)
eq(calls <= 2, true, "run_waves: aborts after the failing wave instead of running all")

-- sequential fallback: no spawn/wait available (the offline + degraded case)
local r5, e5 = T.run_waves({1,2,3}, 4, function(n) return n end, nil, nil)
eq(e5, nil, "run_waves: sequential fallback succeeds")
eq(#r5, 3, "run_waves: sequential fallback processes everything")
local _, e6 = T.run_waves({1,2,3}, 4, function(n)
  if n == 2 then return nil, "seq fail" end
  return n
end, nil, nil)
eq(e6, "seq fail", "run_waves: sequential fallback still reports failures")

-- width is clamped, never zero or negative (which would spin forever)
eq(select(1, T.run_waves({1,2}, 0, function(n) return n end, spawn, wait)) ~= nil, true,
   "run_waves: width 0 is clamped, not an infinite loop")
eq(#(select(1, T.run_waves({1,2}, -5, function(n) return n end, spawn, wait))), 2,
   "run_waves: negative width still processes every item")
eq(#(select(1, T.run_waves({}, 8, function(n) return n end, spawn, wait))), 0,
   "run_waves: empty input is a no-op")

-- 19. P2 coverage fixes, each for a surface that was silently unprotected.

-- (a) OpenAI-shaped attachments. `image_url` / `file` matched nothing, so a
-- photo of an ID pasted into an OpenAI-shaped client was neither de-identified
-- NOR stripped -- the one outcome the attachment policy exists to prevent.
local om = T.collect_media({ messages = { { role = "user", content = {
  { type = "text", text = "look at this" },
  { type = "image_url", image_url = { url = "data:image/png;base64,QUJD" } },
  { type = "file", file = { filename = "x.pdf", file_data = "data:application/pdf;base64,REVG" } },
} } } })
eq(#om, 2, "openai image_url + file are both collected as attachments")
eq(om[1].source.media_type, "image/png", "image_url data URL parsed to a media type")
eq(om[1].source.data, "QUJD", "image_url base64 payload extracted")
eq(om[1].source.type, "base64", "image_url presents as a base64 source")
eq(om[2].source.media_type, "application/pdf", "file data URL parsed to a media type")

-- the writeback must rebuild the data URL, or redacted bytes never reach the wire
om[1]._skyflow_writeback("WllY")
eq(om[1].image_url.url, "data:image/png;base64,WllY", "redacted bytes written back as a data URL")

-- a REMOTE url has no bytes for us to inspect, so it must present as
-- non-base64 and fall to the `unsupported` policy (strip), not pass through
local rm = T.collect_media({ messages = { { role = "user", content = {
  { type = "image_url", image_url = { url = "https://example.com/licence.png" } },
} } } })
eq(#rm, 1, "a remote image_url is still collected")
eq(rm[1].source.type, "url", "a remote url is NOT presented as base64 (so it gets stripped)")

-- Anthropic shapes must keep working
local am = T.collect_media({ messages = { { role = "user", content = {
  { type = "image", source = { type = "base64", media_type = "image/jpeg", data = "QQ" } },
} } } })
eq(#am, 1, "anthropic image blocks still collected")
eq(am[1].source.media_type, "image/jpeg", "anthropic source untouched")

-- (b) MCP preamble. The injector required doc.messages, but MCP bodies carry
-- params.messages -- so every MCP request was de-identified WITHOUT ever telling
-- the model what the placeholders meant.
local mcp = { params = { messages = { { role = "user", content = "hi" } } } }
T.inject_token_preamble(mcp, "PRE", { "mcp" })
eq(mcp.params.messages[1].role, "system", "mcp: preamble inserted into params.messages")
eq(mcp.params.messages[1].content, "PRE", "mcp: preamble content present")
eq(mcp.params.messages[2].content, "hi", "mcp: original message preserved")

-- openai top-level messages still work
local oa = { messages = { { role = "user", content = "hi" } } }
T.inject_token_preamble(oa, "PRE", { "openai" })
eq(oa.messages[1].role, "system", "openai: unchanged behaviour")

-- (c) the `**` depth guard must fail CLOSED. Previously it returned quietly, so
-- PII buried past the limit was forwarded while the request reported success.
local deep = { v = "SECRET" }
for _ = 1, 40 do deep = { n = deep } end
local dspans = T.collect_spans(
  { messages = { { role = "assistant", content = { { type = "tool_use", input = deep } } } } },
  EP({ profile = "anthropic", request_json_paths = {}, response_json_paths = {} }, "request"))
eq(dspans.depth_exceeded, true, "exceeding the ** depth limit is RECORDED, not silently ignored")

-- a shallow body must not trip it
local shallow = T.collect_spans(
  { messages = { { role = "assistant", content = { { type = "tool_use", input = { a = { b = "x" } } } } } } },
  EP({ profile = "anthropic", request_json_paths = {}, response_json_paths = {} }, "request"))
eq(shallow.depth_exceeded, nil, "a normally-nested body does not trip the depth guard")

-- a non-terminal `**` scans nothing, so it must be reported rather than silently
-- under-scanning
local badp = T.collect_spans({ a = { b = "x" } }, { "$.a.**.b" })
eq(badp.bad_path, true, "a non-terminal ** is flagged as a misconfiguration")

-- (d) identifier + tool-description surfaces that egress on every turn
local idconf = { profile = "anthropic", request_json_paths = {}, response_json_paths = {} }
local idspans = T.collect_spans({
  metadata = { user_id = "jane@acme.com" },
  tools = { { name = "lookup", description = "search records for Jane Doe",
              input_schema = { properties = { q = { description = "e.g. Jane Doe" } } } } },
  messages = { { role = "user", content = "hi" } },
}, EP(idconf, "request"))
local idfound = {}
for _, sp in ipairs(idspans) do idfound[sp.text] = true end
eq(idfound["jane@acme.com"], true, "metadata.user_id is covered")

-- tool SCHEMAS are deliberately NOT in the default path set. Claude Desktop
-- resends ~30 tool definitions every turn, so scanning their descriptions added
-- ~130 spans to EVERY request -- a 10x amplification that pushed a
-- fifteen-character message past max_spans and got it refused with 413, which the
-- client showed the user as "Request too large".
eq(idfound["search records for Jane Doe"], nil,
   "tools[].description is NOT scanned by default (10x span amplification)")
eq(idfound["e.g. Jane Doe"], nil,
   "input_schema property descriptions are NOT scanned by default")

-- There is no longer an opt-in for them: the paths are not configurable, so the
-- span-amplification decision above is now the only behaviour. Re-enabling the
-- surface means editing PROFILE_PATHS and raising max_spans in the same change.

-- Tool enums and defaults stay unscanned. Tokenizing a value the provider
-- validates against would break the tool contract, so the built-in paths reach
-- neither -- not even via the tool-description paths, were those ever enabled.
local enumspans = T.collect_spans({ tools = { { name = "t",
  input_schema = { properties = { status = { ["enum"] = { "OPEN", "CLOSED" }, default = "OPEN" } } } } } },
  T.effective_paths("request", { "anthropic" }))
eq(#enumspans, 0, "tool enums/defaults are intentionally left alone")

-- A path that duplicates one already in the profile base must not double the
-- work. The DEPLOYED config did exactly this: response_json_paths was set to
-- "$.content[*].text", which is already the anthropic response default, so every
-- assistant text block was collected twice and sent to Detect twice -- double
-- latency and double cost on the response leg, with identical output.
local dupconf = { profile = "anthropic", request_json_paths = {},
                  response_json_paths = { "$.content[*].text" } }
eq(#EP(dupconf, "response"), 1, "a redundant path is deduped, not appended")
local dupdoc = { content = { { type = "text", text = "one" }, { type = "text", text = "two" } } }
eq(#T.collect_spans(dupdoc, EP(dupconf, "response")), 2,
   "two text blocks yield two spans, not four")
-- Dedupe still earns its place on the UNION: an ambiguous body detects as both
-- chat formats, and the two share paths, so without it every shared path would
-- collect its spans twice.
local uni = T.effective_paths("request", { "anthropic", "openai" })
local uniseen = {}
for _, pth in ipairs(uni) do
  eq(uniseen[pth], nil, "union is deduped: " .. pth)
  uniseen[pth] = true
end

-- 20. SSE emitter fidelity. This emitter is an ALLOWLIST, so every content type
-- Anthropic adds was silently discarded -- invisible content loss, and history
-- corruption when the client replays a turn missing blocks.
local fid = T.doc_to_sse({
  -- `type = "message"` is what is_anthropic_message() dispatches on; without it
  -- doc_to_sse takes the OpenAI path and emits a chat.completion chunk instead.
  type = "message",
  id = "m1", model = "mm", role = "assistant", stop_reason = "end_turn",
  content = {
    { type = "text", text = "see this" },
    { type = "server_tool_use", id = "srv1", name = "web_search", input = { q = "x" } },
    { type = "web_search_tool_result", tool_use_id = "srv1", content = { { title = "T" } } },
  },
  usage = { input_tokens = 10, output_tokens = 5,
            cache_read_input_tokens = 900, cache_creation_input_tokens = 40 },
})
eq(fid:find("server_tool_use", 1, true) ~= nil, true,
   "an unknown block type is passed through, not dropped")
eq(fid:find("web_search_tool_result", 1, true) ~= nil, true,
   "a second unknown block type also survives")
eq(fid:find('"text_delta"', 1, true) ~= nil, true, "known text blocks still emit a text_delta")
-- 3 blocks -> message_start + 3x(start[,delta]+stop) + message_delta + message_stop
eq(select(2, fid:gsub("event: content_block_start", "")), 3,
   "every block gets a content_block_start, including unknown ones")

-- usage fidelity: rebuilding usage with only output_tokens hid prompt-cache cost,
-- so a fully cached conversation looked like it paid full price every turn
eq(fid:find("cache_read_input_tokens", 1, true) ~= nil, true,
   "message_delta carries cache_read_input_tokens")
eq(fid:find("cache_creation_input_tokens", 1, true) ~= nil, true,
   "message_delta carries cache_creation_input_tokens")
eq(fid:find("input_tokens", 1, true) ~= nil, true, "message_delta carries input_tokens")

-- citations ride on a text block and were lost
local cit = T.doc_to_sse({ type = "message", id = "m", role = "assistant", content = {
  { type = "text", text = "quoted", citations = { { type = "char_location" } } } } })
eq(cit:find("citations_delta", 1, true) ~= nil, true, "citations on a text block are re-emitted")

-- an EMPTY text block must STILL be dropped: emitting it makes the client
-- persist and replay `text: ""`, which the API rejects on the next turn with
-- "text content blocks must be non-empty"
local empt = T.doc_to_sse({ type = "message", id = "m", role = "assistant",
  content = { { type = "text", text = "" } } })
eq(empt:find("event: content_block_start", 1, true) == nil, true,
   "an empty text block is still dropped (replaying it breaks the NEXT turn)")

-- OpenAI include_usage: the final chunk must have EMPTY choices + usage, and only
-- when the client asked. Silently omitting it made token accounting read as zero.
local no_usage = T.doc_to_sse({ id = "c1", object = "chat.completion", model = "m",
  choices = { { message = { role = "assistant", content = "hi" }, finish_reason = "stop" } },
  usage = { prompt_tokens = 5, completion_tokens = 2, total_tokens = 7 } }, false)
eq(no_usage:find("total_tokens", 1, true) == nil, true,
   "no usage chunk when include_usage was not requested")
local with_usage = T.doc_to_sse({ id = "c1", object = "chat.completion", model = "m",
  choices = { { message = { role = "assistant", content = "hi" }, finish_reason = "stop" } },
  usage = { prompt_tokens = 5, completion_tokens = 2, total_tokens = 7 } }, true)
eq(with_usage:find("total_tokens", 1, true) ~= nil, true,
   "usage chunk IS emitted when include_usage was requested")
eq(select(2, with_usage:gsub("data: ", "")), 3,
   "include_usage yields content chunk + usage chunk + [DONE]")
eq(with_usage:find("[DONE]", 1, true) ~= nil, true, "[DONE] still terminates the stream")


print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURES"))
os.exit(fails == 0 and 0 or 1)

-- ---------------------------------------------------------------------------
-- 24. Wire-format detection replaces the `profile` config field.
--
-- WHY THIS EXISTS: `profile` was an enum an operator set by hand, and the OpenAI
-- and Anthropic request shapes OVERLAP at `$.messages[*].content`. So pointing an
-- Anthropic route at `profile: openai` did not error, did not warn, and did not
-- look broken -- it scanned ONE of four sensitive spans and sent the other three
-- to the provider in clear text. These cases pin both halves: that detection gets
-- the format right, and that the under-scan it prevents stays prevented.
local DESKTOP_BODY = {
  model = "claude-sonnet-4-5",
  system = { { type = "text", text = "You assist Sarah Chen, employee sarah@acme.com" } },
  messages = {
    { role = "user", content = { { type = "text", text = "my card is 4111111111111111" } } },
    { role = "user", content = { { type = "tool_result", tool_use_id = "t1",
        content = { { type = "text", text = "patient David Okafor, SSN 123-45-6789" } } } } },
  },
  metadata = { user_id = "sarah@acme.com" },
}

eq(T.detect_formats(DESKTOP_BODY, "request")[1], "anthropic",
   "a real Claude Desktop body is detected as anthropic")

-- The leak, measured. Under the old wrong-profile config this body yielded 1 span.
local det = T.collect_spans(DESKTOP_BODY,
  EP3({ request_json_paths = {}, response_json_paths = {} },
                    "request", T.detect_formats(DESKTOP_BODY, "request")))
eq(#det, 4, "detection reaches all four sensitive spans (the old openai profile got 1)")
local dfound = {}
for _, sp in ipairs(det) do dfound[sp.text] = true end
eq(dfound["You assist Sarah Chen, employee sarah@acme.com"], true, "system prompt scanned")
eq(dfound["patient David Okafor, SSN 123-45-6789"], true, "tool_result scanned")
eq(dfound["sarah@acme.com"], true, "metadata.user_id scanned")

-- OpenAI-only discriminators.
eq(T.detect_formats({ messages = { { role = "system", content = "s" } } }, "request")[1],
   "openai", "a system ROLE is openai (illegal in anthropic)")
eq(T.detect_formats({ model = "gpt-4o", messages = { { role = "user", content = "hi" } } },
   "request")[1], "openai", "gpt- model name resolves an otherwise ambiguous body")
eq(T.detect_formats({ prompt = "hi" }, "request")[1], "openai", "legacy prompt is openai")
eq(T.detect_formats({ messages = { { role = "user",
     content = { { type = "image_url", image_url = {} } } } } }, "request")[1],
   "openai", "image_url blocks are openai")

-- MCP is JSON-RPC.
eq(T.detect_formats({ jsonrpc = "2.0", method = "tools/call",
     params = { arguments = {} } }, "request")[1], "mcp", "jsonrpc tag is mcp")

-- Ambiguity returns BOTH rather than guessing, because unioning the path sets
-- over-scans (a non-matching path yields no spans) while guessing under-scans.
local amb = T.detect_formats({ messages = { { role = "user", content = "hi" } } }, "request")
eq(#amb, 2, "an undecidable chat body returns both candidates")
local ambpaths = EP3({ request_json_paths = {}, response_json_paths = {} },
                                   "request", amb)
local hasuser, hasprompt = false, false
for _, pth in ipairs(ambpaths) do
  if pth == "$.user" then hasuser = true end
  if pth == "$.prompt" then hasprompt = true end
end
eq(hasuser and hasprompt, true,
   "the union carries openai-only paths, so an ambiguous body cannot under-scan")
-- and the union must still be deduped: both formats share $.messages[*].content
local ambseen = {}
for _, pth in ipairs(ambpaths) do
  eq(ambseen[pth], nil, "union is deduped: " .. pth .. " appears once")
  ambseen[pth] = true
end

-- Response shapes are disjoint, so no union is needed there.
eq(T.detect_formats({ choices = { {} } }, "response")[1], "openai", "choices -> openai")
eq(T.detect_formats({ type = "message", content = {} }, "response")[1], "anthropic",
   "anthropic message envelope -> anthropic")
eq(T.detect_formats({ result = { content = {} } }, "response")[1], "mcp", "result -> mcp")

-- An unrecognised body yields NO paths, which is what the request-leg guard in
-- handler.lua fails closed on. Returning an empty list rather than defaulting to
-- some format is the point: a silent no-op is the failure mode being removed.
eq(#T.detect_formats({ widget = "x" }, "request"), 0, "an unknown shape detects nothing")
eq(#EP3({ request_json_paths = {}, response_json_paths = {} }, "request", {}),
   0, "no format and no explicit paths yields nothing to scan -- guard territory")
-- ...but explicit paths still work for exactly that case (the old `generic`).
eq(#EP3({ request_json_paths = { "$.widget" }, response_json_paths = {} },
                      "request", {}), 1, "explicit paths cover an unrecognised shape")

-- Ambiguity must NOT produce an openai-style system message: `role: "system"` is
-- illegal in the Anthropic API and earns a hard 400, whereas a top-level `system`
-- string is valid Anthropic and merely ignored by OpenAI. Fail soft, not hard.
local ambdoc = { messages = { { role = "user", content = "hi" } } }
T.inject_token_preamble(ambdoc, "PRE", { "anthropic", "openai" })
eq(ambdoc.system, "PRE", "ambiguous preamble uses the top-level system field")
eq(ambdoc.messages[1].role, "user", "and does NOT prepend an anthropic-illegal system message")
