-- kong.plugins.skyflow-ai-data-control.handler
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
--   * auth    -> STS delegation only (RFC 8693): exchange the CALLER's IdP
--                token for a short-lived Skyflow bearer whose `ctx` is their
--                signed claims. The gateway holds NO Skyflow credential.
--   * reidentify strategy `detokenize` (vault /detokenize API)
--   * per-span concurrency, streaming `reassemble`
-- See docs/contributing/skyflow-integration.md and docs/contributing/development.md.

local http  = require "resty.http"
local cjson = require "cjson.safe"

-- A SEPARATE decoder for LLM request/response bodies, because those bodies must
-- round-trip byte-for-byte in shape and plain cjson cannot do it: Lua has one
-- table type, so `[]` and `{}` both decode to an empty table and both re-encode
-- as `{}`. Anthropic rejects that with `tools: Input should be a valid array`,
-- which is exactly what broke Claude Desktop's title-generation call -- it sends
-- `tools: []`, and every rewritten request came back 400 while the visible
-- conversation (which sends a populated `tools`) worked fine.
--
-- decode_array_with_array_mt stamps decoded arrays with cjson.array_mt, so the
-- encoder emits `[]`. It is set on a private instance rather than the shared
-- module: this is a global toggle, and flipping it on the `cjson` every other
-- plugin and Kong core shares would change their encodings too.
local body_json = cjson
do
  local ok_new, inst = pcall(function () return cjson.new() end)
  if ok_new and inst and inst.decode_array_with_array_mt then
    inst.decode_array_with_array_mt(true)
    body_json = inst
  end
end

-- Upstream LLM responses are commonly gzip-encoded; we must inflate before we
-- can parse/re-identify them. Kong bundles a gzip helper -- load it guarded so
-- the plugin still loads if the module path differs on a given build.
local ok_gzip, kgzip = pcall(require, "kong.tools.gzip")
local inflate_gzip = ok_gzip and kgzip and kgzip.inflate_gzip or nil

local kong = kong
local ngx  = ngx

local SkyflowAIDataControl = { PRIORITY = 775, VERSION = "0.3.0" }

--==========================================================================--
-- Pure helpers (no Kong/ngx deps) — exercised offline via SkyflowAIDataControl._test
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

  if tok == "**" then
    -- Recursive descent: every string leaf at any depth below here. Needed
    -- because a tool call's `input` is arbitrary caller-defined JSON -- a
    -- single-level `*` reaches `input.soql` but not `input.filter.name`, and
    -- "de-identified only at the depth we guessed" is not a property worth
    -- having. Terminal only: `**` followed by more tokens is not supported.
    if type(node) ~= "table" then return end
    if not last then
      -- `**` is terminal-only. Silently collecting nothing would mean a
      -- misconfigured path de-identifies NOTHING while the request still
      -- succeeds, so record it and let the caller fail closed.
      out.bad_path = true
      return
    end
    local function deep(parent, depth)
      if depth > 32 then
        -- FAIL CLOSED, not open. This guard exists for the Lua stack, but
        -- returning quietly meant a caller could bury PII at depth 33 and the
        -- request would report success with that subtree unscanned -- the exact
        -- opposite of the max_spans contract 30 lines below, which refuses
        -- rather than partially de-identifying.
        out.depth_exceeded = true
        return
      end
      for k, v in pairs(parent) do
        if type(v) == "string" then
          out[#out + 1] = { parent = parent, key = k, text = v }
        elseif type(v) == "table" then
          deep(v, depth + 1)
        end
      end
    end
    deep(node, 1)

  elseif tok == "[*]" then
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
    -- tool_calls arguments is a JSON *string*, so it is one span rather than a
    -- subtree. Same replayed-history exposure as the Anthropic `input.**` path.
    request  = { "$.messages[*].content", "$.messages[*].content[*].text", "$.input", "$.prompt",
                 "$.messages[*].tool_calls[*].function.arguments",
                 -- OpenAI's end-user identifier fields, same reasoning as
                 -- Anthropic's metadata.user_id
                 "$.user", "$.messages[*].name" },
    -- see the anthropic note above: the OpenAI equivalents
    -- ("$.tools[*].function.description",
    --  "$.tools[*].function.parameters.properties.*.description") are opt-in for
    -- the same span-amplification reason.
    response = { "$.choices[*].message.content", "$.choices[*].text" },
  },
  anthropic = {
    -- The tool_result paths cover both the string and text-block forms -- agent
    -- traffic surfaces most sensitive data THERE (file contents, command
    -- output), not in the user's typed message.
    --
    -- `$.system[*].text` is NOT redundant with `$.system`. Claude Desktop sends
    -- the system prompt as an ARRAY OF BLOCKS, and `$.system` only matches the
    -- scalar form, so the entire system prompt went out unscanned. Verified
    -- against live traffic: a hostname that Detect tokenized inside a
    -- tool_result appeared in the clear in the system prompt of the SAME
    -- request.
    --
    -- `input.**` covers a replayed tool_use. This one only bites once tool
    -- inputs are restored to plain text: the gateway hands the client a real
    -- value, the client stores it in history, and history replays on every
    -- subsequent turn -- so without this path the value we just restored goes
    -- straight back to the provider in the clear. Re-tokenizing is also
    -- self-consistent: tokenization is deterministic, so the model sees the same
    -- token it saw the first time.
    -- `metadata.user_id` is Anthropic's documented end-user identifier, and teams
    -- routinely put a raw email in it. Tokenizing it is semantically safe because
    -- tokens are deterministic, so any join or rate-limit keyed on it still
    -- works -- it just stops being an identifier the provider can read.
    request  = { "$.system", "$.system[*].text",
                 "$.messages[*].content[*].text", "$.messages[*].content",
                 "$.messages[*].content[*].content", "$.messages[*].content[*].content[*].text",
                 "$.messages[*].content[*].input.**",
                 "$.metadata.user_id" },
    -- NOT in the default set, deliberately, and this was learned the hard way.
    --
    -- Tool SCHEMAS do egress on every turn and MCP descriptions are often
    -- generated from customer systems, so scanning them is genuinely useful:
    --   "$.tools[*].description"
    --   "$.tools[*].input_schema.properties.*.description"
    -- But Claude Desktop resends ~30 tool definitions on EVERY request, each with
    -- a description plus many property descriptions. Adding these produced ~130
    -- extra spans on every call -- a 10x amplification -- so a fifteen-character
    -- "new task" blew straight through max_spans and was refused with 413, which
    -- the client reports to the user as "Request too large". Availability lost to
    -- a low-yield surface.
    --
    -- They are also STATIC: identical on every turn of a conversation, so scanning
    -- them re-spends the same Detect calls forever. Until there is a cache keyed
    -- on the tool set, this belongs behind an explicit opt-in.
    --
    -- To enable, add them to `request_json_paths` (which MERGES with the base set)
    -- and raise max_spans to at least 512 in the same change.
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
    if conf.profile == "generic" then
      -- Dedupe here too. This branch used to return `override` verbatim, so a
      -- path listed twice under profile=generic collected every span twice, spent
      -- twice at Detect, and counted twice against max_spans -- a premature 413.
      local seen, out = {}, {}
      for _, s in ipairs(override) do
        if not seen[s] then seen[s] = true; out[#out + 1] = s end
      end
      return out
    end
    -- Dedupe. collect_spans walks each path independently and appends, so a path
    -- listed twice collects every matching span twice -- and then every span is
    -- sent to Detect twice, doubling response-leg latency and cost for no effect.
    -- This is not hypothetical: the deployed config set
    -- `response_json_paths: ["$.content[*].text"]`, which is ALREADY the anthropic
    -- response default, so every assistant text block was detokenized twice.
    -- Merging is the documented way to extend a profile, so the merge has to be
    -- idempotent rather than trusting operators to know the base set by heart.
    local merged, seen = {}, {}
    for _, s in ipairs(base) do
      if not seen[s] then seen[s] = true; merged[#merged + 1] = s end
    end
    for _, s in ipairs(override) do
      if not seen[s] then seen[s] = true; merged[#merged + 1] = s end
    end
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

-- Base64url (RFC 4648 §5, unpadded) in pure Lua: used for JWT assembly. Pure
-- (no ngx dep) so the offline unit test can exercise it.
local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B64_REVERSE   -- lazily built decode table

local function b64url_encode(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i), s:byte(i + 1), s:byte(i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local quad = {
      math.floor(n / 262144) % 64, math.floor(n / 4096) % 64,
      math.floor(n / 64) % 64,     n % 64,
    }
    for j = 1, (c and 4) or (b and 3) or 2 do
      local d = quad[j]
      out[#out + 1] = B64_ALPHABET:sub(d + 1, d + 1)
    end
  end
  return table.concat(out)
end

local function b64url_decode(s)
  if type(s) ~= "string" then return nil end
  if not B64_REVERSE then
    B64_REVERSE = { ["+"] = 62, ["/"] = 63 }   -- accept the standard alphabet too
    for i = 1, 64 do B64_REVERSE[B64_ALPHABET:sub(i, i)] = i - 1 end
  end
  s = s:gsub("=+$", "")
  if #s % 4 == 1 then return nil end
  local out, n, bits = {}, 0, 0
  for i = 1, #s do
    local v = B64_REVERSE[s:sub(i, i)]
    if not v then return nil end
    n, bits = n * 64 + v, bits + 6
    if bits >= 8 then
      bits = bits - 8
      out[#out + 1] = string.char(math.floor(n / 2 ^ bits) % 256)
      n = n % 2 ^ bits
    end
  end
  return table.concat(out)
end

-- Extract the `exp` claim (unix seconds) from a JWT without full JSON parsing;
-- 0 when absent/unparseable. The token endpoint returns no expiresIn field, so
-- the bearer's own exp drives cache refresh.
local function jwt_exp(token)
  local payload = type(token) == "string" and token:match("^[^%.]+%.([^%.]+)")
  local raw = payload and b64url_decode(payload)
  if not raw then return 0 end
  return tonumber(raw:match('"exp"%s*:%s*(%d+)')) or 0
end






--==========================================================================--
-- Kong-coupled helpers
--==========================================================================--

-- The request-wide deadline, clamped so it can never be shorter than a single
-- attempt's timeout. This used to be a schema entity check that REJECTED such a
-- config; it moved here when custom validation functions had to leave schema.lua
-- for Konnect plugin streaming. Clamping is the better behaviour anyway: a
-- deadline below one timeout is a typo rather than an intent, and silently
-- honouring the larger value beats refusing to load the config.
-- Tell the model what the placeholders ARE.
--
-- Without this, a model handed `[NAME_xFaTgtN]` frequently editorialises about
-- it -- "all names have been redacted from this document, so I cannot provide
-- those details" -- or apologises, or substitutes "[redacted]". That answer is
-- useless twice over: the user wanted the content, and the gateway had a
-- perfectly good token it could have re-identified on the way back.
--
-- Injected AFTER de-identification on purpose: the preamble carries no PII, so
-- scanning it would spend a Detect call and consume the max_spans budget for
-- nothing. It is also prepended per request rather than persisted, so it cannot
-- accumulate across turns.
--
-- The "reproduce them exactly, including the brackets" line is load-bearing.
-- Re-identification resolves a token by matching it; a model that rewrites
-- `[NAME_xFaTgtN]` as `NAME_xFaTgtN` or `**[NAME_xFaTgtN]**` can defeat the
-- lookup, and the caller then sees a token instead of the real value.
-- The example suffixes are deliberately the literal word EXAMPLE rather than
-- token-shaped strings. An earlier version used [NAME_a1b2c3], which read as a
-- real token: it appeared on the wire on every request, and had the model ever
-- echoed it back, re-identification would have tried to resolve a token that was
-- never in any vault. EXAMPLE cannot collide with a generated suffix, and if it
-- ever does surface in output it is self-evidently the instruction leaking
-- rather than a lookup that silently failed.
local DEFAULT_TOKEN_PREAMBLE =
  "Some values in this conversation appear as placeholders: an entity type and a "
  .. "short code in square brackets, such as [NAME_EXAMPLE], "
  .. "[EMAIL_ADDRESS_EXAMPLE] or [ACCOUNT_NUMBER_EXAMPLE].\n\n"
  .. "Treat each placeholder as the real value it stands for. They are stable: "
  .. "the same placeholder always refers to the same person or thing, so you can "
  .. "compare, group and reason about them normally.\n\n"
  .. "When you refer to one, reproduce it exactly as written, including the "
  .. "square brackets. Do not translate, shorten, reformat, emphasise or "
  .. "pluralise a placeholder.\n\n"
  -- Each clause below corresponds to an observed failure. The bare "do not
  -- remark on the redaction" wording was not enough on summarization tasks: the
  -- model still described documents as "containing redacted personal
  -- information" and listed which fields were "redacted", which is commentary
  -- about the transport rather than an answer about the content.
  .. "Write as though the placeholders were the underlying values. Do not "
  .. "mention, describe, count or draw attention to the placeholders themselves. "
  .. "Do not characterise the material as redacted, masked, anonymised, "
  .. "sanitised or privacy-protected, and do not add caveats or disclaimers "
  .. "about it -- that is a property of how the text reached you, not a fact "
  .. "about its content, and the reader already knows it.\n\n"
  .. "Nothing is missing or unavailable, so never say that it is, apologise for "
  .. "it, or decline on those grounds. Do not guess or invent what a placeholder "
  .. "might stand for. Simply answer the request, using the placeholders exactly "
  .. "where you would have used the underlying values."

-- Prepend the preamble to whatever system prompt the caller already sent,
-- handling every shape the two profiles use: absent, a plain string, or an
-- Anthropic array of content blocks.
local function inject_token_preamble(doc, text, profile)
  if profile == "openai" or profile == "mcp" then
    -- MCP bodies carry their messages at `params.messages`, not at the top
    -- level (see PROFILE_PATHS.mcp). Requiring doc.messages made this a silent
    -- no-op for every MCP request: the placeholders were injected nowhere and
    -- the model was never told what they meant -- precisely the editorialising
    -- failure the preamble exists to prevent.
    local msgs = doc.messages
    if type(msgs) ~= "table" and type(doc.params) == "table" then
      msgs = doc.params.messages
    end
    if type(msgs) ~= "table" then
      -- No message array anywhere. Say so rather than returning quietly: the
      -- caller believes the model was briefed, and silence is why this went
      -- unnoticed.
      kong.log.warn("skyflow: token preamble not injected -- no message array on ",
                    "this ", tostring(profile), " request shape")
      return
    end
    local first = msgs[1]
    if type(first) == "table" and first.role == "system" and type(first.content) == "string" then
      first.content = text .. "\n\n" .. first.content
    else
      table.insert(msgs, 1, { role = "system", content = text })
    end
    return
  end

  -- anthropic / generic: top-level `system`
  local sys = doc.system
  if sys == nil then
    doc.system = text
  elseif type(sys) == "string" then
    doc.system = text .. "\n\n" .. sys
  elseif type(sys) == "table" then
    -- array of content blocks; a leading text block keeps cache_control intact
    -- on the caller's own blocks, which matters for prompt caching
    table.insert(sys, 1, { type = "text", text = text })
  end
end

local function request_deadline(conf)
  local budget_ms = conf.deadline_ms or 0
  if conf.timeout_ms and budget_ms < conf.timeout_ms then
    budget_ms = conf.timeout_ms
  end
  return ngx.now() + (budget_ms / 1000)
end

local function base_url(conf)
  if conf.skyflow_base_url_override and conf.skyflow_base_url_override ~= "" then
    return (conf.skyflow_base_url_override:gsub("/$", ""))
  end
  return "https://" .. conf.cluster_id .. ".vault.skyflowapis.com"
end

--==========================================================================--
-- Skyflow auth: STS delegation (RFC 8693) -- the only mechanism
--
-- Exchange the caller's IdP token at Skyflow's STS endpoint for a short-lived
-- bearer whose `ctx` IS their signed claims. POST token_uri with
-- { grant_type="urn:ietf:params:oauth:grant-type:token-exchange",
--   subject_token, subject_token_type, service_account_id } -> { accessToken }.
-- The response carries no expiry, so we decode the bearer's own exp claim.
--
-- Note what is absent: no private key, no assertion signing, no gateway-held
-- credential of any kind. Skyflow also IGNORES context supplied by the caller
-- of an exchange, so there is no ctx to assemble here -- tenant/role/purpose
-- belong in the IdP token, where they arrive signed.
--==========================================================================--

-- Per-worker caches. Keys change whenever the SA / roles / resolved ctx
-- change, so config updates and per-caller contexts mint naturally. Bounded by
-- wholesale reset -- simple, and a re-mint is cheap relative to eviction logic.
local TOKEN_CACHE, TOKEN_CACHE_N = {}, 0 -- cache_key -> { token, exp }
local TOKEN_CACHE_MAX = 256
-- Lifetime of the service-account ASSERTION we sign. Not configurable: Skyflow
-- caps the lifetime of the bearer it returns server-side, so a knob here could
-- only ever narrow something the vault already governs.
local JWT_ASSERTION_TTL = 3600






-- ============================ STS (Profile B) ============================
-- Exchange the CALLER's IdP token for a Skyflow bearer (RFC 8693 delegation).
--
-- Differences from the service-account path below that matter operationally:
--   * the gateway holds NO Skyflow private key -- nothing to sign, nothing to
--     leak; it forwards an identity it was given
--   * ctx comes entirely from the IdP's claims (per the account's STS config
--     allowlist). The plugin's context/context_headers/context_kong settings
--     are IGNORED here: Skyflow silently drops any context supplied in the
--     exchange body, so gateway-asserted attributes are impossible -- put them
--     in the IdP token (Entra app roles / claims-mapping policy) instead.
--   * Skyflow records these as Auth Mode: STS with the human in Subject and
--     Context ID, while Actor stays the service account (delegation semantics)
--   * the minted bearer inherits the IdP token's `exp`, so its lifetime is
--     bounded by the caller's session, not a fixed hour

local STS_GRANT = "urn:ietf:params:oauth:grant-type:token-exchange"
local STS_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:jwt"  -- the only one accepted

-- How many attributes Skyflow actually put in the minted bearer's ctx. Logged
-- because the allowlist is an INTERSECTION: ctx = the STS config's
-- contextClaims that are also present in the caller's token. A claim the
-- policy needs but the IdP omitted disappears silently, so surface the count.
local function jwt_ctx_count(token)
  local payload = token and token:match("^[^.]+%.([^.]+)%.")
  local decoded = payload and b64url_decode(payload)
  local claims = decoded and cjson.decode(decoded)
  local ctx = type(claims) == "table" and claims.ctx
  if type(ctx) ~= "table" then return 0 end
  local n = 0
  for _ in pairs(ctx) do n = n + 1 end
  return n
end

-- Cheap, local pre-checks so a junk or misdirected token fails at the gateway
-- instead of costing a round trip. Signature verification is Skyflow's job
-- (it fetches the issuer's JWKS); this only rejects the obvious.
-- Returns claims, or nil + message + "identity". Every failure in here is the
-- CALLER's to fix -- a fresh sign-in, or pointing at the right gateway -- so it
-- must surface as 401, never as a 502 that implicates Skyflow.
local function precheck_caller_token(token, sts)
  local payload = token and token:match("^[^.]+%.([^.]+)%.")
  if not payload then return nil, "caller token is not a JWT", "identity" end
  local decoded = b64url_decode(payload)
  local claims = decoded and cjson.decode(decoded)
  if type(claims) ~= "table" then
    return nil, "caller token payload is not JSON", "identity"
  end
  if claims.exp and tonumber(claims.exp) and tonumber(claims.exp) <= ngx.now() then
    return nil, "caller identity token has expired; sign in again", "identity"
  end
  if sts.expected_issuer and sts.expected_issuer ~= "" and claims.iss ~= sts.expected_issuer then
    return nil, "caller token issuer mismatch", "identity"
  end
  if sts.expected_audience and sts.expected_audience ~= "" then
    local aud = claims.aud
    local ok = aud == sts.expected_audience
    if not ok and type(aud) == "table" then
      for _, a in ipairs(aud) do if a == sts.expected_audience then ok = true break end end
    end
    if not ok then return nil, "caller token audience mismatch", "identity" end
  end
  -- A subject is REQUIRED, because the STS bearer cache is keyed on it. Defaulting
  -- a missing subject to a placeholder collapsed every subject-less caller into
  -- one slot, so caller B was handed the bearer minted from caller A's identity --
  -- B's vault operations audited as A, and evaluated against A's ctx.
  if not claims.sub and not claims.oid then
    return nil, "caller identity token has no subject (sub/oid); refusing to "
                .. "exchange a token that cannot be attributed", "identity"
  end
  return claims
end

-- Exchange the caller's token; cache per caller token identity.
local function sts_bearer(conf, deadline)
  local sts = conf.credentials.sts
  if not sts.service_account_id or sts.service_account_id == "" then
    return nil, "credentials.sts.service_account_id is required"
  end

  local header = sts.token_header
  if header == nil or header == "" then header = "authorization" end
  -- Prefer the copy stashed during access. The request leg CLEARS the inbound
  -- Authorization header so the caller's IdP token cannot egress to the model
  -- provider, and kong.service.request.clear_header mutates the SAME nginx
  -- request table that kong.request.get_header reads -- so by the response phase
  -- the header is gone. Re-identification needs a bearer for the same caller, so
  -- read the stash first and fall back to the header for the access-phase call
  -- that populates it.
  local ctxp = kong.ctx and kong.ctx.plugin
  local raw = (ctxp and ctxp.caller_token) or kong.request.get_header(header)
  if not raw or raw == "" then
    return nil, "no caller identity token in '" .. header
                .. "'; this gateway cannot assert an identity on your behalf",
           "identity"
  end
  if ctxp then ctxp.caller_token = raw end
  local token = raw:match("^[Bb]earer%s+(.+)$") or raw

  local claims, perr, pkind = precheck_caller_token(token, sts)
  if not claims then return nil, perr, pkind end

  -- one cached Skyflow bearer per (caller subject, token expiry): a new sign-in
  -- or a refreshed token mints a new one, and distinct callers never share
  local cache_key = "sts\n" .. sts.service_account_id .. "\n"
                    .. tostring(claims.sub or claims.oid or "?") .. "\n"
                    .. tostring(claims.exp or 0)
  local hit = TOKEN_CACHE[cache_key]
  if hit and hit.exp - (conf.token_skew_seconds or 300) > ngx.now() then
    return "Bearer " .. hit.token
  end

  local token_uri = sts.token_uri
  if not token_uri or token_uri == "" then
    token_uri = "https://manage.skyflowapis.com/v1/auth/sts/token"
  end
  local body = cjson.encode({
    grant_type = STS_GRANT,
    subject_token = token,
    subject_token_type = STS_TOKEN_TYPE,
    service_account_id = sts.service_account_id,
  })

  local attempts, last_err = (conf.retries or 0) + 1, nil
  for _ = 1, attempts do
    if deadline and ngx.now() >= deadline then
      return nil, "deadline exceeded exchanging caller identity"
    end
    local httpc = http.new()
    httpc:set_timeout(conf.timeout_ms)
    local res, err = httpc:request_uri(token_uri, {
      method = "POST", body = body,
      headers = { ["Content-Type"] = "application/json" },
      ssl_verify = true,
      keepalive_timeout = conf.keepalive_idle_ms, keepalive_pool = conf.keepalive_pool_size,
    })
    if res and res.status == 200 then
      local data = cjson.decode(res.body)
      local minted = data and data.accessToken
      if not minted or minted == "" then return nil, "sts endpoint returned no accessToken" end
      local exp = jwt_exp(minted)
      if exp == 0 then exp = math.floor(ngx.now()) + 300 end
      if TOKEN_CACHE_N >= TOKEN_CACHE_MAX then TOKEN_CACHE, TOKEN_CACHE_N = {}, 0 end
      if not TOKEN_CACHE[cache_key] then TOKEN_CACHE_N = TOKEN_CACHE_N + 1 end
      TOKEN_CACHE[cache_key] = { token = minted, exp = exp }
      kong.log.info("skyflow: exchanged caller identity for STS bearer (",
                    claims.preferred_username or claims.email or claims.sub or "?",
                    ", ctx attrs=", jwt_ctx_count(minted),
                    ", ttl=", math.floor(exp - ngx.now()), "s)")
      return "Bearer " .. minted
    elseif res and res.status >= 400 and res.status < 500 and res.status ~= 429 then
      -- 4xx here is a configuration OR identity problem, and the distinction
      -- matters to whoever gets the error. 401/403 means Skyflow refused the
      -- caller's token (bad signature, wrong audience, expired) -> the caller
      -- signs in again. Any other 4xx is our own STS misconfiguration -- no
      -- config for this (service account, issuer) pair, say -- and telling the
      -- caller to re-authenticate would send them chasing our bug.
      local kind = (res.status == 401 or res.status == 403) and "identity" or "config"
      return nil, "sts exchange rejected: HTTP " .. res.status .. " "
                  .. string.sub(res.body or "", 1, 180), kind
    else
      last_err = err or ("HTTP " .. tostring(res and res.status))
    end
  end
  return nil, "sts exchange failed: " .. tostring(last_err)
end


-- A static Skyflow API key or bearer, forwarded as-is.
--
-- No exchange, no caching, no identity: every request reaches the vault as this
-- one credential, so `$ctx.<attr>` policies cannot tell callers apart and the
-- audit trail names the gateway rather than a person. That is the trade-off the
-- operator accepted by selecting this method; it is not the default.
local function bearer_token_value(conf)
  local b = conf.credentials.bearer_token
  if not b or not b.api_key or b.api_key == "" then
    return nil, "credentials.bearer_token.api_key is required for method=bearer_token", "config"
  end
  return "Bearer " .. b.api_key
end

-- Build the `ctx` claim for a gateway-minted assertion.
--
-- Only reachable from jwt_credential: under sts the claim set is the IdP's and
-- Skyflow ignores anything we add, and under bearer_token there is no assertion
-- to put claims in. See schema.lua for why that asymmetry is enforced by the
-- shape of the config rather than by a check.
-- Takes no configuration on purpose. Every claim here is derived by the gateway
-- at request time, which is precisely why it can be trusted: the caller cannot
-- forge any of it.
--
-- The claim set is meant to represent the CONTEXT OF THE REQUEST honestly, which
-- is deliberately two kinds of fact:
--   who/where  kong_consumer (only when a Kong auth plugin verified the client),
--              kong_client_ip, kong_request_id
--   what it hit kong_route, kong_service
-- Both are legitimate policy inputs -- "this caller may detokenize" and "requests
-- through this route may detokenize" are both real rules -- and neither is
-- caller-assertable. What is EXCLUDED is any value the caller simply claimed
-- about itself in a header.
--
-- Verified against the live Skyflow token endpoint: a `ctx` claim in the
-- service-account assertion is propagated verbatim into the minted bearer, so
-- vault policies can key on $ctx.kong_route / $ctx.kong_service /
-- $ctx.kong_consumer / $ctx.kong_client_ip. Without the claim, the bearer carries
-- no ctx at all. An earlier version let operators map request HEADERS into
-- claims, which inverted that -- it fed caller-controlled values into the claim
-- set the vault uses for policy decisions, so anyone who could reach the gateway
-- could assert their own tenant or purpose.
local function build_ctx()
  local ctx = {}
  local consumer = kong.client.get_consumer()
  if consumer then ctx.kong_consumer = consumer.username or consumer.id end
  local route = kong.router.get_route()
  if route then ctx.kong_route = route.name or route.id end
  local service = kong.router.get_service()
  if service then ctx.kong_service = service.name or service.id end
  ctx.kong_client_ip = kong.client.get_forwarded_ip()
  -- Correlation id. Skyflow's audit trail records that a field was detokenized;
  -- this is what lets you tie that entry back to the specific gateway request
  -- that caused it, which is the difference between "something detokenized this"
  -- and "this request, from this caller, at this time, did".
  -- kong.request.get_id(), NOT the x-kong-request-id HEADER. Reading the header
  -- took a value the CALLER controls and put it in the claim set the vault trusts
  -- -- flatly contradicting the rule stated above, forging the audit correlation
  -- id, and letting a client steer this function's cache key. get_id() returns
  -- the id Kong itself assigned.
  if kong.request and kong.request.get_id then
    ctx.kong_request_id = kong.request.get_id()
  end
  return next(ctx) and ctx or nil
end

-- Mint a Skyflow bearer from a service-account JWT the GATEWAY signs (RS256).
--
-- Weaker than sts -- the identity is asserted by us, not signed by an IdP, and
-- the host now holds a private key worth stealing -- but it is the only option
-- when callers have no IdP token to delegate: service-to-service traffic, batch
-- jobs, a client the gateway already authenticated some other way.
--
-- `resty.openssl.pkey` is required LAZILY, not at module scope. Two reasons: an
-- sts-only or bearer-only deployment should not load a crypto library it never
-- calls, and if a future sandbox mode drops it from the allowlist the failure is
-- confined to this method instead of refusing to load the whole plugin. It is in
-- the STRICT allowlist today, which `lax` extends, so streamed code can use it.
local function jwt_credential_bearer(conf, deadline)
  local jc = conf.credentials.jwt_credential
  if not jc or not jc.service_account_json or jc.service_account_json == "" then
    return nil, "credentials.jwt_credential.service_account_json is required "
                .. "for method=jwt_credential", "config"
  end
  local sa = cjson.decode(jc.service_account_json)
  -- type(privateKey) == "string" is load-bearing, not defensive noise:
  -- resty.openssl.pkey.new(table) GENERATES a fresh 2048-bit key instead of
  -- erroring. A malformed credential therefore produced a perfectly well-formed
  -- assertion that Skyflow could not verify -- an opaque 4xx -- while burning
  -- ~64ms of event-loop-blocking keygen per request.
  if type(sa) ~= "table" or type(sa.privateKey) ~= "string" or sa.privateKey == ""
     or type(sa.clientID) ~= "string" then
    return nil, "service_account_json is not a Skyflow service-account credential "
                .. "(expected clientID, keyID, tokenURI, privateKey)", "config"
  end
  local token_uri = sa.tokenURI
  if not token_uri or token_uri == "" then
    token_uri = "https://manage.skyflowapis.com/v1/auth/sa/oauth/token"
  end

  local ctx = build_ctx()
  -- Cache on everything that changes the assertion, so a per-request ctx (from
  -- context_headers) does not silently reuse another caller's bearer.
  -- Cache key: everything that changes the assertion, EXCLUDING the per-request
  -- correlation id.
  --
  -- kong_request_id is unique per request, so including it made the key unique per
  -- request and the cache could never hit: every single request signed a 2048-bit
  -- RS256 assertion and did a live HTTPS exchange with Skyflow, continuously
  -- refilling and wiping the 256-slot cache, and making token_skew_seconds dead
  -- config. Measured: 3 token-endpoint POSTs across 3 request ids, where 1 was
  -- correct.
  --
  -- The key also covers the CREDENTIAL. Without that, rotating
  -- service_account_json (or fixing a broken one) kept serving the bearer minted
  -- from the previous key until the entry aged out.
  local ctx_key = {}
  if ctx then
    for k, v in pairs(ctx) do
      if k ~= "kong_request_id" then ctx_key[#ctx_key + 1] = k .. "=" .. tostring(v) end
    end
    table.sort(ctx_key)
  end
  local cache_key = "jwt\n" .. tostring(sa.clientID) .. "\n" .. tostring(sa.keyID) .. "\n"
                    .. b64url_encode(tostring(sa.privateKey)):sub(1, 24) .. "\n"
                    .. table.concat(ctx_key, "&")
  local hit = TOKEN_CACHE[cache_key]
  if hit and hit.exp - (conf.token_skew_seconds or 300) > ngx.now() then
    return "Bearer " .. hit.token
  end

  local ok, pkey_lib = pcall(require, "resty.openssl.pkey")
  if not ok then
    return nil, "method=jwt_credential needs resty.openssl.pkey, which this "
                .. "runtime does not permit; use method=sts", "config"
  end
  local key, kerr = pkey_lib.new(sa.privateKey)
  if not key then
    return nil, "service-account private key is unusable: " .. tostring(kerr), "config"
  end

  local now = math.floor(ngx.now())
  local claims = {
    iss = sa.clientID, key = sa.keyID, aud = token_uri, sub = sa.clientID,
    exp = now + JWT_ASSERTION_TTL, iat = now,
  }
  if ctx then claims.ctx = ctx end

  local signing_input = b64url_encode(cjson.encode({ alg = "RS256", typ = "JWT", kid = sa.keyID }))
                        .. "." .. b64url_encode(cjson.encode(claims))
  local sig, serr = key:sign(signing_input, "sha256")
  if not sig then return nil, "signing the service-account assertion failed: "
                              .. tostring(serr), "config" end
  local assertion = signing_input .. "." .. b64url_encode(sig)

  local body = cjson.encode({
    grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer",
    assertion = assertion,
  })
  local attempts, last_err = (conf.retries or 0) + 1, nil
  for _ = 1, attempts do
    if deadline and ngx.now() >= deadline then
      return nil, "deadline exceeded minting a service-account bearer"
    end
    local httpc = http.new()
    httpc:set_timeout(conf.timeout_ms)
    local res, err = httpc:request_uri(token_uri, {
      method = "POST", body = body,
      headers = { ["Content-Type"] = "application/json" },
      ssl_verify = true,
      keepalive_timeout = conf.keepalive_idle_ms, keepalive_pool = conf.keepalive_pool_size,
    })
    if res and res.status == 200 then
      local data = cjson.decode(res.body)
      local minted = data and (data.accessToken or data.access_token)
      if not minted or minted == "" then
        return nil, "service-account token endpoint returned no accessToken"
      end
      local exp = jwt_exp(minted)
      -- Conservative fallback, matching the STS path. Assuming the assertion's
      -- own TTL would cache a short-lived bearer well past its real expiry and
      -- serve it until it started 401ing.
      if exp == 0 then exp = math.floor(ngx.now()) + 300 end
      if TOKEN_CACHE_N >= TOKEN_CACHE_MAX then TOKEN_CACHE, TOKEN_CACHE_N = {}, 0 end
      if not TOKEN_CACHE[cache_key] then TOKEN_CACHE_N = TOKEN_CACHE_N + 1 end
      TOKEN_CACHE[cache_key] = { token = minted, exp = exp }
      kong.log.info("skyflow: minted service-account bearer (ctx attrs=",
                    ctx and jwt_ctx_count(minted) or 0,
                    ", ttl=", math.floor(exp - ngx.now()), "s)")
      return "Bearer " .. minted
    elseif res and res.status >= 400 and res.status < 500 and res.status ~= 429 then
      -- Unlike sts, a 4xx here is never the caller's fault: the assertion is
      -- ours. Classifying it as "identity" would tell a user to sign in again
      -- over our own misconfiguration.
      return nil, "service-account token request rejected: HTTP " .. res.status .. " "
                  .. string.sub(res.body or "", 1, 180), "config"
    else
      last_err = err or ("HTTP " .. tostring(res and res.status))
    end
  end
  return nil, "service-account token request failed: " .. tostring(last_err)
end

-- Resolve the Authorization header value for this request.
--
-- Three methods, and the choice is a real security trade-off rather than a
-- preference. `sts` exchanges the CALLER's IdP token: the gateway holds no
-- Skyflow credential at all, so compromising the host yields no vault access,
-- and the identity Skyflow audits is the human's, IdP-signed. It stays the
-- default for exactly that reason. `jwt_credential` puts a private key on the
-- gateway and asserts identity itself. `bearer_token` gives the vault no caller
-- identity whatsoever.
local function auth_value(conf, deadline)
  local method = (conf.credentials and conf.credentials.method) or "sts"
  if method == "bearer_token" then return bearer_token_value(conf) end
  if method == "jwt_credential" then return jwt_credential_bearer(conf, deadline) end
  return sts_bearer(conf, deadline)
end

-- POST JSON to Skyflow with a per-attempt timeout and deadline-bounded retries.
-- Classify a 4xx from Skyflow. Pure, and exported for tests, because the one
-- case that matters here is impossible to reach through the HTTP path offline
-- and cost a real user a finished answer when it was miscategorised.
--
-- Returns (message, kind). `kind == "unmatched_token"` means the vault could not
-- resolve a token in the text -- the model reformatted a placeholder we issued
-- (`[NAME_x]` bulleted to `- x`, bolded, split). That is model behaviour, not a
-- gateway or vault fault, and on the RESPONSE leg it must degrade to "leave that
-- span tokenized" rather than destroy a complete response. On 2026-07-29 it did
-- the latter: 404 -> generic client error -> on_error=deny -> 502, and a
-- finished 289-token answer was discarded.
--
-- The body marker is load-bearing. Treating ANY 404 as benign would silently
-- forward tokenized text when the base URL or vault_id is simply wrong, which is
-- exactly the misconfiguration that must fail closed.
local function classify_client_error(status, body)
  body = tostring(body or "")
  if status == 404 and (body:find("Detokenization failed", 1, true)
                        or body:find("is invalid", 1, true)) then
    return "skyflow 404 unmatched token", "unmatched_token"
  end
  if status == 403 then
    return "skyflow 403 (grant the Detect de-identify/re-identify permission)", "forbidden"
  end
  return "skyflow status " .. tostring(status) .. " (client error, not retried)", "client_error"
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
    elseif res and res.status >= 400 and res.status < 500 and res.status ~= 429 then
      -- client error (bad payload / vault_id / credential): retrying can't help,
      -- so fail fast instead of burning the whole deadline budget.
      local cerr, ckind = classify_client_error(res.status, res.body)
      return nil, cerr, ckind
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
--==========================================================================--
-- Binary attachments (images, PDFs)
--
-- The text path rewrites strings; an `image`/`document` content block carries
-- base64 bytes that no string API can touch, so those attachments reached the
-- provider unmodified. This closes that gap using Detect's **V2** file API,
-- which takes base64 in JSON (no multipart) and returns a redacted file --
-- exactly the shape an Anthropic block already gives us.
--
-- Verified against a live vault: a card image and a patient-intake PDF both
-- came back with every entity blacked out, and re-scanning the OUTPUT found
-- zero entities where the originals found six. Latency: images <1-3s, PDF ~10s.
--
-- Deliberate scoping:
--   * V2 is used ONLY here. Text stays on V1 -- it is tested and deployed, and
--     V2's text path would need per-entity `destination` values for
--     VAULT_TOKEN, which is a separate migration.
--   * Redaction is burned into pixels, so unlike text it is ONE-WAY: there is
--     nothing to re-identify on the response leg.
--   * ENTITY_UNIQUE_COUNTER (not VAULT_TOKEN) is used for files, which avoids
--     V2's destination requirement. Consequence: the original is not stored in
--     the vault, so there is no authorized-retrieval path for the unredacted
--     file yet. Vault-backed originals are a follow-up.

-- Anthropic media_type -> Detect V2 `dataFormat`. NOTE the enum is lowercase
-- here while every other V2 enum is SCREAMING_SNAKE ("PNG" is rejected).
-- webp is intentionally absent: Anthropic accepts it, Detect does not support
-- it, so it can never be de-identified -- it falls to the unsupported policy.
local MEDIA_FORMATS = {
  ["image/png"]  = "png",
  ["image/jpeg"] = "jpg",
  ["image/gif"]  = "gif",
  ["image/bmp"]  = "bmp",
  ["image/tiff"] = "tif",
  ["application/pdf"] = "pdf",
}

-- Collect every base64 attachment block, including ones nested in tool_result
-- content (an agent reading a file produces exactly that).
-- Adapt an OPENAI-shaped attachment to the Anthropic `source` view the rest of
-- this file speaks. Without this, `type == "image_url"` and `type == "file"`
-- matched nothing: an OpenAI-shaped client pasting a photo of a driver's licence
-- got it neither de-identified NOR stripped -- the one outcome the attachment
-- policy exists to make impossible. (LiteLLM handled both shapes already.)
--
-- Both carry the bytes as a data URL, so parse it into media_type + base64 and
-- install a `source` table plus a writeback so the redacted bytes land back in
-- the field the provider actually reads.
local function adapt_openai_media(block)
  local url, setter
  if block.type == "image_url" and type(block.image_url) == "table" then
    url = block.image_url.url
    setter = function(v) block.image_url.url = v end
  elseif block.type == "file" and type(block.file) == "table" then
    url = block.file.file_data
    setter = function(v) block.file.file_data = v end
  end
  if type(url) ~= "string" then return nil end

  local mime, b64 = url:match("^data:([%w%-%+%./]+);base64,(.*)$")
  if not mime then
    -- A remote http(s) URL: the gateway never sees the bytes, so it cannot
    -- inspect them. Present it as a non-base64 source so the `unsupported`
    -- policy applies (strip by default) rather than forwarding it blind.
    block.source = { type = "url", media_type = nil }
    block._skyflow_writeback = setter
    return block
  end
  block.source = { type = "base64", media_type = mime, data = b64 }
  block._skyflow_writeback = function(v) setter("data:" .. mime .. ";base64," .. v) end
  return block
end

local function collect_media(data)
  local out = {}
  local function walk(blocks)
    if type(blocks) ~= "table" then return end
    for _, block in ipairs(blocks) do
      if type(block) == "table" then
        local t = block.type
        if t == "image" or t == "document" then
          out[#out + 1] = block
        elseif t == "image_url" or t == "file" then
          local adapted = adapt_openai_media(block)
          if adapted then out[#out + 1] = adapted end
        elseif type(block.content) == "table" then
          walk(block.content)   -- tool_result carrying attachments
        end
      end
    end
  end
  for _, msg in ipairs(data.messages or {}) do
    if type(msg) == "table" and type(msg.content) == "table" then walk(msg.content) end
  end
  return out
end

-- Replace an attachment with a text marker so the turn still makes sense.
local function strip_media(block, why)
  for k in pairs(block) do block[k] = nil end
  block.type = "text"
  block.text = "[attachment removed before egress: " .. why .. "]"
end

-- Submit one file and poll to completion. Returns redacted base64, entity
-- count. Bounded by the request deadline; a timeout is an error, never a pass.
local function deidentify_file(conf, authz, b64, fmt, deadline)
  local m = conf.media or {}
  -- Attachment entity scope defaults to ALL, deliberately BROADER than the text
  -- path's list. Measured: the 8-entity text list found 4 entities in a card
  -- image where ALL found 6 (it missed CREDIT_CARD_EXPIRATION and more) -- and
  -- unlike a text span, nobody eyeballs an image before it egresses. Set
  -- media.entities to narrow it.
  local entities = {}
  for _, e in ipairs((m.entities and #m.entities > 0) and m.entities or {}) do
    entities[#entities + 1] = { entityType = e:upper(),
                                deidentificationType = "ENTITY_UNIQUE_COUNTER" }
  end
  if #entities == 0 then
    entities[1] = { entityType = "ALL", deidentificationType = "ENTITY_UNIQUE_COUNTER" }
  end

  local media_cfg = {
    -- BOTH fields are required once an image block exists: an absent
    -- outputProcessedImage is treated as false (not the documented true) and
    -- an absent maskingMethod defaults to NONE, which the API then refuses.
    image = { outputProcessedImage = true,
              maskingMethod = m.masking_method or "BLACKBOX" },
  }
  if fmt == "pdf" then
    media_cfg.document = { pdf = { processingMode = m.pdf_processing_mode or "OCR" } }
  end

  local detect = { entities = entities, returnEntities = "ALL" }
  -- Non-text objects. MUST be specific types, never `ALL`: measured, ALL/REDACT
  -- blacks out every detected object including ordinary text runs, so the
  -- provider receives a solid black rectangle -- protective but useless, and it
  -- also collapses the reported entity count to 1. FACE+SIGNATURE gives full
  -- PII text redaction (6/6 entities) AND face coverage, leaving labels and
  -- non-sensitive content readable.
  local obj_types = m.redact_object_types
  if obj_types and #obj_types > 0 then
    local objs = {}
    for _, t in ipairs(obj_types) do
      objs[#objs + 1] = { entityType = t, deidentificationType = "REDACT" }
    end
    detect.objectEntities = objs
  end

  local body = cjson.encode({
    dataSource = "BASE64", value = b64, dataFormat = fmt,
    configuration = { vaultId = conf.vault_id, detect = detect, media = media_cfg },
  })

  local httpc = http.new()
  httpc:set_timeout(conf.timeout_ms)
  local headers = { ["Authorization"] = authz, ["Content-Type"] = "application/json" }
  if conf.account_id and conf.account_id ~= "" then
    headers["X-SKYFLOW-ACCOUNT-ID"] = conf.account_id
  end

  local res, err = httpc:request_uri(base_url(conf) .. "/v2/detect/deidentify/file",
    { method = "POST", body = body, headers = headers, ssl_verify = true })
  if not res then return nil, nil, "submit failed: " .. tostring(err) end
  if res.status ~= 200 then
    return nil, nil, "submit HTTP " .. res.status .. " " .. string.sub(res.body or "", 1, 160)
  end
  local run_id = (cjson.decode(res.body) or {}).runId
  if not run_id then return nil, nil, "no runId in submit response" end

  local poll_url = base_url(conf) .. "/v2/detect/runs/" .. run_id
                   .. "?vaultId=" .. conf.vault_id
  local interval = (m.poll_interval_ms or 500) / 1000
  while true do
    if deadline and ngx.now() >= deadline then
      return nil, nil, "deadline exceeded while de-identifying attachment"
    end
    ngx.sleep(interval)
    local p = http.new()
    p:set_timeout(conf.timeout_ms)
    local pr, perr = p:request_uri(poll_url, { method = "GET", headers = headers, ssl_verify = true })
    if not pr then return nil, nil, "poll failed: " .. tostring(perr) end
    if pr.status ~= 200 then
      return nil, nil, "poll HTTP " .. pr.status .. " " .. string.sub(pr.body or "", 1, 160)
    end
    local run = cjson.decode(pr.body) or {}
    if run.status == "SUCCESS" then
      local redacted, n_entities
      for _, o in ipairs(run.output or {}) do
        if o.processedFileType == "REDACTED_FILE" and o.processedFile then
          redacted = o.processedFile
        elseif o.processedFileType == "ENTITIES" and o.processedFile then
          -- detections live in this attachment, not the top-level `entities`
          -- array (which comes back empty for files)
          local decoded = b64url_decode((o.processedFile:gsub("+", "-"):gsub("/", "_")))
          local list = decoded and cjson.decode(decoded)
          if type(list) == "table" then n_entities = #list end
        end
      end
      if not redacted then return nil, nil, "run succeeded with no REDACTED_FILE output" end
      return redacted, n_entities, nil
    elseif run.status == "FAILED" then
      return nil, nil, "detect run failed: " .. tostring(run.message)
    end
  end
end

-- Apply the media policy to every attachment in the request.
-- Returns processed count, stripped count, or nil+err when failing closed.
local function process_media(conf, authz, data, deadline)
  local m = conf.media or {}
  local mode = m.mode or "deidentify"
  if mode == "passthrough" then return 0, 0 end

  local blocks = collect_media(data)
  if #blocks == 0 then return 0, 0 end

  local processed, stripped = 0, 0
  for _, block in ipairs(blocks) do
    local src = block.source or {}
    local fmt = MEDIA_FORMATS[src.media_type or ""]
    local unsupported =
      (src.type ~= "base64") and ("source type '" .. tostring(src.type) .. "' cannot be inspected")
      or (not fmt) and ("format " .. tostring(src.media_type) .. " is not supported for de-identification")
      or nil

    if mode == "strip" then
      strip_media(block, "policy: attachments stripped")
      stripped = stripped + 1
    elseif unsupported then
      -- Never forward something we could not inspect.
      if (m.unsupported or "strip") == "block" then return nil, nil, unsupported end
      strip_media(block, unsupported)
      stripped = stripped + 1
    elseif mode == "block" then
      return nil, nil, "policy: attachments are not permitted"
    else
      local size = #(src.data or "")
      if m.max_file_bytes and m.max_file_bytes > 0 and size > m.max_file_bytes then
        return nil, nil, "attachment exceeds max_file_bytes (" .. size .. " base64 bytes)"
      end
      local redacted, n, err = deidentify_file(conf, authz, src.data, fmt, deadline)
      if not redacted then return nil, nil, err end
      src.data = redacted
      -- an adapted OpenAI block stores its bytes in a data URL, so put them back
      if block._skyflow_writeback then block._skyflow_writeback(redacted) end
      processed = processed + 1
      kong.log.info("skyflow: de-identified ", fmt, " attachment (",
                    n or "?", " entities redacted)")
    end
  end
  return processed, stripped
end

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
  -- third return value carries the failure KIND; "unmatched_token" is benign on
  -- this leg and the caller degrades instead of failing the whole response.
  local data, err, kind = skyflow_post(conf, authz, "/v1/detect/reidentify/string",
                                       payload, deadline)
  if not data then return nil, err, kind end
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
-- kong.request.get_raw_body() returns nil when nginx spooled the request body to
-- a temp file instead of keeping it in memory -- which happens once the body
-- exceeds client_body_buffer_size. Small curls stay in memory; real API clients
-- (e.g. a coding agent sending a large system prompt + tool schemas) do not, so
-- without this fallback the plugin would deny every genuine agent request as
-- "body unavailable". Read the spooled file directly to recover the full body.
local function read_request_body()
  local raw = kong.request.get_raw_body()
  if raw ~= nil then return raw end
  local path = ngx.req.get_body_file()
  if not path then return nil end
  -- `io` is a sandboxed global too: absent when this plugin is STREAMED from the
  -- control plane. Without the fallback a body spooled to disk cannot be read, so
  -- say so rather than returning a bare nil that reads as "no body".
  if not io or not io.open then
    kong.log.err("skyflow: request body was spooled to disk but `io` is unavailable ",
                 "(streamed plugin sandbox); raise client_body_buffer_size so bodies ",
                 "stay in memory")
    return nil
  end
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

-- Move the caller's IdP token out of the shared nginx request headers and into
-- per-request plugin context, FIRST THING, before any path that can return.
--
-- Two separate leaks close here:
--   * egress -- Kong's ai-proxy drivers only ever set_header their provider
--     credential and never clear an inbound Authorization (verified in
--     kong/llm/drivers/anthropic.lua). Anthropic authenticates with x-api-key,
--     so nothing downstream overwrites ours and the caller's enterprise token
--     would ride all the way to api.anthropic.com. (The OpenAI route escapes
--     this only because its credential occupies Authorization itself -- an
--     accident, not a design.)
--   * LOGS -- clear_header mutates the same table file-log's serializer reads.
--     This used to run ~40 lines below, AFTER the 401/413/422 early returns, so
--     every rejected request serialized its (invalid or expired) caller token to
--     stdout and on to CloudWatch, where retention is unlimited. Rejected
--     requests are exactly the ones carrying suspect credentials.
--
-- Nothing inward needs the header: internal routes are guarded by source IP, and
-- whichever bearer we end up using travels in our OWN request to Skyflow, never
-- in the proxied one. sts_bearer reads ctx.caller_token in preference to the
-- header, so stashing before clearing is what keeps that method working at all.
--
-- Deliberately unconditional across auth methods. Under bearer_token and
-- jwt_credential there is no caller token to exchange, but the client may still
-- have sent an Authorization header to authenticate to the GATEWAY -- and that
-- must not ride along to the model provider either. The `sts` lookup below is
-- only about which header name to read; the clearing happens regardless.
local function take_caller_token(conf, ctx)
  local sts = conf.credentials and conf.credentials.sts
  local hdr = (sts and sts.token_header) or "authorization"
  local raw = kong.request.get_header(hdr)
  if raw and raw ~= "" then ctx.caller_token = raw end
  if kong.service and kong.service.request and kong.service.request.clear_header then
    kong.service.request.clear_header(hdr)
    -- also clear Authorization when the token arrived in a custom header, so a
    -- separate bearer cannot ride along to the provider
    if hdr:lower() ~= "authorization" then
      kong.service.request.clear_header("Authorization")
    end
  end
end

-- Run `fn` over `items` in concurrent waves of at most `width`, returning
-- (results, first_error). Hoisted out of the access phase and exported so the
-- concurrency semantics are testable without a live Kong: the offline harness has
-- no ngx.thread, and a fail-closed gateway cannot afford an untested path that
-- decides whether de-identification failures are noticed.
--
-- Guarantees, in order of importance:
--   * a failure in ANY item is reported -- never dropped. A swallowed error here
--     would turn "de-identification failed" into "forwarded in the clear".
--   * every spawned thread is waited on, even after a failure is known, so none
--     outlives the request.
--   * no locking needed: OpenResty light threads are cooperatively scheduled on a
--     single worker, so only one runs Lua at a time.
--   * degrades to a plain sequential loop where light threads are unavailable,
--     which is also what makes it testable offline.
local function run_waves(items, width, fn, spawn, wait)
  local results, first_err = {}, nil
  width = math.max(1, math.floor(tonumber(width) or 1))
  local concurrent = spawn and wait
  local i = 1
  while i <= #items and not first_err do
    local last = math.min(i + width - 1, #items)
    if concurrent and last > i then
      local threads = {}
      for j = i, last do threads[#threads + 1] = spawn(fn, items[j]) end
      for t = 1, #threads do
        local ok_t, value, err = wait(threads[t])
        if not ok_t then
          first_err = first_err or ("worker crashed: " .. tostring(value))
        elseif value == nil then
          first_err = first_err or (err or "unknown worker failure")
        else
          results[#results + 1] = value
        end
      end
    else
      for j = i, last do
        -- pcall, to match the concurrent branch. ngx.thread.wait already reports
        -- a thrown error as `ok == false`; without pcall here the same fault
        -- would UNWIND out of the sequential path instead of being reported,
        -- so the two branches would fail differently for identical input.
        local ok_c, value, err = pcall(fn, items[j])
        if not ok_c then
          first_err = first_err or ("worker crashed: " .. tostring(value))
          break
        end
        if value == nil then
          first_err = first_err or (err or "unknown worker failure")
          break
        end
        results[#results + 1] = value
      end
    end
    i = last + 1
  end
  return results, first_err
end

local function run_access(conf, ctx)
  take_caller_token(conf, ctx)

  local raw = read_request_body()
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

  -- The deadline covers SA bearer minting too, so a hung token endpoint can't
  -- stall the request beyond deadline_ms.
  local deadline = request_deadline(conf)
  local authz, aerr, akind = auth_value(conf, deadline)
  if not authz then
    -- Auth failures ALWAYS fail closed -- never forward raw PII -- regardless of
    -- posture. But WHICH failure matters to whoever reads the error:
    --
    --   identity -> 401. The caller's token is missing, expired, or meant for a
    --     different gateway. They fix it by signing in again. Reporting this as
    --     502 sends them to investigate Skyflow for their own expired session,
    --     which is exactly the wrong place -- and a client that retries on 502
    --     but re-authenticates on 401 will spin forever on the wrong one.
    --   anything else -> 502. Skyflow is unreachable, or our own STS config is
    --     wrong; telling the caller to re-authenticate would send them chasing
    --     our bug.
    if akind == "identity" then
      kong.log.warn("skyflow: caller identity rejected: ", aerr)
      return { deny = true, status = 401,
               body = { message = "request blocked: " .. tostring(aerr) } }
    end
    kong.log.err("skyflow auth error: ", aerr)
    return { deny = true, status = 502, body = { message = "request blocked: auth unavailable" } }
  end

  -- (the caller's token was stashed and stripped by take_caller_token at the top
  -- of this function, before any path that can return)

  -- Will this request's response actually be re-emitted as SSE by :response()?
  -- Downgrading the client's stream is only safe if the answer is yes; otherwise
  -- we would strip `stream: true` and then leave nobody to turn the buffered JSON
  -- back into an event stream, and a client that asked for text/event-stream
  -- hangs or gets JSON. The /probe route (reidentify disabled) is exactly that
  -- case, so it must keep streaming straight through -- showing the caller the
  -- tokenized SSE the provider produced, which is that route's whole purpose.
  -- Config rule that used to be a schema entity check (see schema.lua on why it
  -- moved). A `generic` profile with neither JSON paths nor text content type
  -- has nothing to look at, so it would de-identify precisely nothing while
  -- reporting success -- the exact silent-passthrough this plugin must not do.
  if conf.profile == "generic" and conf.content_type ~= "text"
     and (not conf.request_json_paths or #conf.request_json_paths == 0) then
    kong.log.err("skyflow: profile 'generic' requires request_json_paths or content_type=text")
    return { deny = true, status = 500,
             body = { message = "request blocked: gateway misconfigured "
                                .. "(profile 'generic' requires request_json_paths)" } }
  end

  local will_reemit = conf.reidentify.enabled
                      and conf.reidentify.streaming ~= "passthrough"

  local json_mode = wants_json(conf, kong.request.get_header("Content-Type"))

  -- Build the list of text spans to process.
  local doc, spans
  if json_mode then
    doc = body_json.decode(raw)
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

  -- Binary attachments first: they are the one payload shape the text path
  -- cannot touch, and a redacted image changes `doc`, so this must happen
  -- before the body is re-encoded. Runs even when there are no text spans --
  -- an image-only turn still needs protecting.
  local media_processed, media_stripped = 0, 0
  if json_mode then
    local media_err
    media_processed, media_stripped, media_err = process_media(conf, authz, doc, deadline)
    if not media_processed then
      kong.log.err("skyflow: attachment policy blocked request: ", tostring(media_err))
      return { deny = true, status = 415,
               body = { message = "request blocked: " .. tostring(media_err) } }
    end
    if media_processed > 0 or media_stripped > 0 then
      kong.log.info("skyflow: attachments -- ", media_processed, " de-identified, ",
                    media_stripped, " stripped")
    end
  end

  if #spans == 0 then
    -- No text to process, but an attachment may have been rewritten above, so
    -- the body still has to go out re-encoded. Mirrors the main rewrite path
    -- below, including the force-non-streaming behaviour.
    if (media_processed > 0 or media_stripped > 0) and not conf.dry_run then
      if doc.stream == true and will_reemit then
        ctx.client_stream = true
        doc.stream = false
        -- Remember `include_usage` before discarding stream_options. We strip
        -- it because the upstream call is forced non-streaming, but a client that
        -- asked for a usage chunk got NONE -- silently, so token accounting just
        -- read as zero. The buffered response carries usage, so it can be
        -- re-emitted as the final chunk below.
        if type(doc.stream_options) == "table" and doc.stream_options.include_usage then
          ctx.want_usage_chunk = true
        end
        doc.stream_options = nil
      end
      local enc, eerr = body_json.encode(doc)
      if not enc then return fail_action(conf, ctx, "re-encode failed: " .. tostring(eerr)) end
      kong.service.request.set_raw_body(enc)
      kong.service.request.set_header("Content-Length", #enc)
      -- Mark the request processed even though no TEXT span was tokenized.
      -- Without this the response phase bails at the `not ctx.deidentified`
      -- gate, and two things break: (1) we just downgraded the client's stream
      -- to a buffered request, so nobody re-emits SSE and a streaming client
      -- hangs -- an image pasted with no accompanying text does exactly this;
      -- (2) in a multi-turn session the model echoes tokens minted on EARLIER
      -- turns, and those would come back to the caller unresolved.
      ctx.deidentified = true
      if conf.reidentify.streaming ~= "passthrough" then
        kong.service.request.clear_header("Accept-Encoding")
        kong.service.request.enable_buffering()
      end
    end
    return { ok = true }
  end

  -- Fail closed if the payload carries more sensitive-text fields than we will
  -- process. Never forward a partially de-identified body -- the untouched
  -- extras would leak upstream in the clear.
  -- A structural limit was hit while collecting spans, so part of the body was
  -- never scanned. Same posture as max_spans: refuse rather than forward a
  -- partially de-identified body.
  if spans.depth_exceeded then
    kong.log.err("skyflow: request nests deeper than the 32-level scan limit; blocking")
    return { deny = true, status = 413,
             body = { message = "request blocked: nested too deeply to de-identify" } }
  end
  if spans.bad_path then
    kong.log.err("skyflow: a configured json path uses '**' in a non-terminal ",
                 "position, which scans nothing; blocking rather than under-scanning")
    return { deny = true, status = 500,
             body = { message = "request blocked: gateway de-identification path misconfigured" } }
  end
  if #spans > conf.max_spans then
    kong.log.err("skyflow: ", #spans, " spans exceed max_spans=", conf.max_spans, "; blocking request")
    return { deny = true, status = 413,
             body = { message = "request blocked: too many fields to de-identify (max_spans)" } }
  end


  -- De-identify every span, CONCURRENTLY, in waves of conf.max_concurrency.
  --
  -- This loop used to be sequential, which made latency linear in span count:
  -- measured on real traffic, Detect costs ~104ms per span at the median and
  -- ~403ms at p90, so a large agent request spent essentially all of its
  -- wall-clock here (worst observed: 26.3s of a 31.4s request). It also made
  -- `max_concurrency` -- which the schema has always declared, the security doc
  -- describes as a DoS control, and the partner schema ships -- dead config.
  --
  -- ngx.thread.spawn is permitted in the access phase, and lua-resty-http uses
  -- cosockets, so the requests genuinely overlap. OpenResty light threads are
  -- cooperatively scheduled on one worker, so `by_token`/`counts` need no
  -- locking: only one thread runs Lua at a time and the aggregation below
  -- happens after wait().
  --
  -- Fail-closed is the delicate part. A dropped thread error would silently
  -- convert "de-identification failed" into "forwarded in the clear", so EVERY
  -- thread's outcome is collected and the first failure aborts the whole request
  -- exactly as the sequential version did. Threads already spawned are waited on
  -- rather than abandoned, so none can outlive the request.
  local by_token, counts = {}, {}
  local pending = {}
  for _, span in ipairs(spans) do
    -- Skip empty spans: agent conversations carry messages with content "" (e.g.
    -- an assistant turn that only made tool calls). Skyflow Detect 400s on empty
    -- text, so leave it untouched rather than fail the whole request.
    if span.text == "" then
      span.processed = span.text
    else
      pending[#pending + 1] = span
    end
  end

  -- One span's worth of work. Defined HERE, not hoisted: it closes over conf,
  -- authz and deadline. An earlier refactor moved run_waves to module scope and
  -- took this definition with it, leaving the call below referencing an
  -- undefined name -- which Lua resolves as a nil global, so every request died
  -- with "worker crashed: attempt to call a nil value" and the gateway fail-closed
  -- into a 502. The offline suite passed throughout, because run_waves is tested
  -- with an injected fake and nothing exercises the access phase itself.
  local function run_span(span)
    local processed, ents = deidentify_text(conf, authz, span.text, deadline)
    if not processed then return nil, ents end   -- on failure `ents` is the error
    span.processed = processed
    return ents
  end

  local width = tonumber(conf.max_concurrency) or 8
  local results, first_err = run_waves(
    pending, width, run_span,
    ngx and ngx.thread and ngx.thread.spawn,
    ngx and ngx.thread and ngx.thread.wait)

  for _, ents in ipairs(results) do
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

  if first_err then
    return fail_action(conf, ctx, first_err)
  end

  ctx.mapping = by_token
  ctx.entities_by_type = counts

  -- Rewrite the outbound body (unless dry-run).
  if not conf.dry_run then
    local newbody
    if json_mode then
      for _, span in ipairs(spans) do span.parent[span.key] = span.processed end
      -- placeholders now exist in the body, so explain them to the model
      local pre = conf.deidentify.token_preamble
      if pre == nil or pre.enabled ~= false then
        local text = (pre and pre.text ~= nil and pre.text ~= "" and pre.text)
                     or DEFAULT_TOKEN_PREAMBLE
        inject_token_preamble(doc, text, conf.profile)
      end
      -- Re-identification must buffer the whole response, which is impossible over
      -- a streamed (SSE) response: a vault token like [NAME_xjv74g] gets split
      -- across chunks and can't be matched. So force the upstream call
      -- non-streaming, remember the client wanted a stream, and re-emit the
      -- re-identified answer as SSE in :response(). (See demo/act2 — real coding
      -- agents always stream.)
      if doc.stream == true and will_reemit then
        ctx.client_stream = true
        doc.stream = false
        -- Remember `include_usage` before discarding stream_options. We strip
        -- it because the upstream call is forced non-streaming, but a client that
        -- asked for a usage chunk got NONE -- silently, so token accounting just
        -- read as zero. The buffered response carries usage, so it can be
        -- re-emitted as the final chunk below.
        if type(doc.stream_options) == "table" and doc.stream_options.include_usage then
          ctx.want_usage_chunk = true
        end
        doc.stream_options = nil
      end
      local enc, eerr = body_json.encode(doc)
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

function SkyflowAIDataControl:access(conf)
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

-- Pure: build the single streaming chunk from a buffered chat.completion. The
-- delta carries the whole answer -- content AND tool_calls, so an agent's tool
-- loop still works. Exposed via _test for offline unit testing.
local function sse_chunk(doc)
  local choice = (doc.choices and doc.choices[1]) or {}
  local delta  = choice.message or { role = "assistant", content = "" }
  -- OpenAI's streamed tool_call deltas carry an `index`; the buffered completion
  -- form omits it. Add it so the client can reassemble the tool calls.
  if type(delta.tool_calls) == "table" then
    for i, tc in ipairs(delta.tool_calls) do tc.index = i - 1 end
  end
  return {
    id = doc.id, object = "chat.completion.chunk",
    created = doc.created, model = doc.model,
    choices = { { index = 0, delta = delta, finish_reason = choice.finish_reason or "stop" } },
  }
end

-- Which policy applies to ONE tool call, by name. See the schema comment on
-- tool_inputs_by_tool for why the tool's name is the right key: it names the
-- destination, and the destination is what decides whether real values may
-- materialize there.
--
-- Exact match beats prefix match, and the LONGEST prefix wins, so a broad rule
-- can be narrowed by a specific one:
--     "mcp__workspace__*"        = "plain_text"   -- runs locally
--     "mcp__workspace__web_fetch" = "tokenized"   -- ...except this one egresses
local function tool_policy(conf, name)
  local reid = conf.reidentify
  local fallback = reid.tool_inputs or "tokenized"
  local by = reid.tool_inputs_by_tool
  if type(by) ~= "table" or type(name) ~= "string" or name == "" then
    return fallback
  end

  local exact = by[name]
  if exact then return exact end

  local best, best_len = nil, -1
  for pattern, treatment in pairs(by) do
    -- plain string ops, not Lua patterns: tool names contain no magic chars but
    -- a config value could, and `find(..., true)` keeps it literal either way.
    local star = pattern:sub(-1) == "*"
    if star then
      local prefix = pattern:sub(1, -2)
      if #prefix > best_len and name:sub(1, #prefix) == prefix then
        best, best_len = treatment, #prefix
      end
    end
  end
  return best or fallback
end

-- Serialize a (re-identified) chat.completion as a minimal SSE stream, so a
-- streaming OpenAI client (e.g. a coding agent) gets the event-stream it asked
-- for even though the gateway had to buffer the full response to re-identify it.
-- One chunk + a [DONE] sentinel. The client renders it at once instead of
-- token-by-token, an acceptable trade for never leaking PII.
local function completion_to_sse(doc, want_usage)
  local out = "data: " .. cjson.encode(sse_chunk(doc)) .. "\n\n"
  -- OpenAI's contract for stream_options.include_usage: a FINAL chunk with an
  -- empty choices array and the usage object. Only sent when the client asked.
  if want_usage and type(doc.usage) == "table" then
    -- cjson.empty_array, NOT setmetatable({}, cjson.array_mt): `setmetatable` is a
    -- GLOBAL, and streamed plugin code runs in the untrusted-Lua sandbox where it
    -- is nil. Under `lax` that produced
    --   "attempt to call global 'setmetatable' (a nil value)"
    -- on the response leg, so every request de-identified fine, reached the
    -- provider, and then 502'd on the way back. The sentinel needs no metatable.
    local empty_choices = cjson.empty_array or {}
    out = out .. "data: " .. cjson.encode({
      id = doc.id, object = "chat.completion.chunk", created = doc.created,
      model = doc.model, choices = empty_choices, usage = doc.usage,
    }) .. "\n\n"
  end
  return out .. "data: [DONE]\n\n"
end

-- True when the buffered upstream body is an Anthropic-native message (e.g.
-- ai-proxy with `llm_format: anthropic`, or a direct Anthropic upstream).
local function is_anthropic_message(doc)
  return doc.type == "message" and type(doc.content) == "table"
end

-- Anthropic Messages counterpart of completion_to_sse: re-emit a buffered
-- (re-identified) message as the event sequence Anthropic streaming clients
-- (e.g. Claude Code) require -- message_start, one start/delta/stop triplet
-- per content block (text and tool_use both supported, so agent tool loops
-- keep working), message_delta with the stop_reason, message_stop.
local function anthropic_message_to_sse(doc)
  -- cjson niceties guarded for non-Kong runtimes (offline tests stub cjson):
  -- array_mt makes the empty content encode as [], null keeps explicit nulls.
  local empty_array = cjson.empty_array or {}   -- sandbox-safe; see note above
  local null = cjson.null
  local function ev(name, data)
    return "event: " .. name .. "\ndata: " .. cjson.encode(data) .. "\n\n"
  end
  local out = { ev("message_start", { type = "message_start", message = {
    id = doc.id, type = "message", role = doc.role or "assistant",
    model = doc.model, content = empty_array,
    stop_reason = null, stop_sequence = null,
    usage = doc.usage or { input_tokens = 0, output_tokens = 0 },
  } }) }
  local idx = -1
  for _, block in ipairs(doc.content) do
    -- Emit each block AS ITS OWN TYPE. Collapsing everything to `text` looks
    -- harmless but corrupts the client's stored history: a `thinking` block has
    -- no `text` field, so it became `text: ""`, the client saved an empty text
    -- block, and replaying that history made the API reject the NEXT turn with
    -- "text content blocks must be non-empty". Extended thinking is on by
    -- default in some clients, so this hit every multi-turn conversation.
    if block.type == "tool_use" then
      idx = idx + 1
      out[#out + 1] = ev("content_block_start", { type = "content_block_start", index = idx,
        content_block = { type = "tool_use", id = block.id, name = block.name, input = {} } })
      out[#out + 1] = ev("content_block_delta", { type = "content_block_delta", index = idx,
        -- body_json, not cjson: a tool's arguments routinely contain empty
        -- arrays, and the shared codec would ship them as `{}` -- the same
        -- shape error that made Anthropic reject `tools: []`.
        delta = { type = "input_json_delta", partial_json = body_json.encode(block.input or {}) } })
      out[#out + 1] = ev("content_block_stop", { type = "content_block_stop", index = idx })

    elseif block.type == "thinking" then
      -- Reasoning text is passed through VERBATIM and never re-identified: the
      -- block carries a signature the provider verifies when the client replays
      -- it, so altering the text would invalidate the turn. Any vault tokens in
      -- reasoning therefore stay tokenized -- cosmetic, and the safe direction.
      idx = idx + 1
      out[#out + 1] = ev("content_block_start", { type = "content_block_start", index = idx,
        content_block = { type = "thinking", thinking = "" } })
      out[#out + 1] = ev("content_block_delta", { type = "content_block_delta", index = idx,
        delta = { type = "thinking_delta", thinking = block.thinking or "" } })
      if block.signature then
        out[#out + 1] = ev("content_block_delta", { type = "content_block_delta", index = idx,
          delta = { type = "signature_delta", signature = block.signature } })
      end
      out[#out + 1] = ev("content_block_stop", { type = "content_block_stop", index = idx })

    elseif block.type == "redacted_thinking" then
      idx = idx + 1
      out[#out + 1] = ev("content_block_start", { type = "content_block_start", index = idx,
        content_block = { type = "redacted_thinking", data = block.data or "" } })
      out[#out + 1] = ev("content_block_stop", { type = "content_block_stop", index = idx })

    elseif type(block.text) == "string" and block.text ~= "" then
      idx = idx + 1
      out[#out + 1] = ev("content_block_start", { type = "content_block_start", index = idx,
        content_block = { type = "text", text = "" } })
      -- citations ride on the text block and are lost if not re-emitted
      if block.citations ~= nil then
        out[#out + 1] = ev("content_block_delta", { type = "content_block_delta", index = idx,
          delta = { type = "citations_delta", citation = block.citations } })
      end
      out[#out + 1] = ev("content_block_delta", { type = "content_block_delta", index = idx,
        delta = { type = "text_delta", text = block.text } })
      out[#out + 1] = ev("content_block_stop", { type = "content_block_stop", index = idx })

    elseif block.type ~= nil and block.type ~= "text" then
      -- UNKNOWN block type -- pass it through verbatim rather than dropping it.
      --
      -- This emitter is an allowlist, so every content type Anthropic adds was
      -- silently discarded: server_tool_use, web_search_tool_result,
      -- mcp_tool_use, document. That is invisible content loss AND history
      -- corruption -- the client stores a turn missing blocks it will replay.
      -- Re-emitting the raw block keeps unknown types intact; the trade is that
      -- their text is not re-identified, which is the safe direction (a token is
      -- not PII) and no worse than dropping them.
      idx = idx + 1
      out[#out + 1] = ev("content_block_start", { type = "content_block_start", index = idx,
        content_block = block })
      out[#out + 1] = ev("content_block_stop", { type = "content_block_stop", index = idx })
    end
    -- an EMPTY text block is still dropped: emitting it makes the client persist
    -- and replay `text: ""`, which the API then rejects with "text content blocks
    -- must be non-empty" on the following turn.
  end
  -- Carry the FULL usage object. Rebuilding it with only output_tokens dropped
  -- cache_read_input_tokens / cache_creation_input_tokens / server_tool_use,
  -- which is what a client needs to attribute prompt-cache cost -- so a cached
  -- conversation looked like it was paying full price for every turn.
  local usage = doc.usage
  if type(usage) ~= "table" then usage = { output_tokens = 0 } end
  out[#out + 1] = ev("message_delta", { type = "message_delta",
    delta = { stop_reason = doc.stop_reason or "end_turn",
              stop_sequence = doc.stop_sequence or null },
    usage = usage })
  out[#out + 1] = ev("message_stop", { type = "message_stop" })
  return table.concat(out)
end

-- Shape-appropriate SSE re-emit for a buffered doc.
local function doc_to_sse(doc, want_usage)
  if is_anthropic_message(doc) then return anthropic_message_to_sse(doc) end
  return completion_to_sse(doc, want_usage)
end

-- Hand the client an SSE stream when we are BAILING OUT of re-identification.
--
-- The access phase downgraded the client's `stream: true` to a buffered upstream
-- call, on the promise that :response() would convert the result back to SSE.
-- Every early return in :response() breaks that promise and ships a JSON body
-- with `Content-Type: text/event-stream`, which a strict client reports as a
-- decode error or simply stalls on. Two of those paths were reachable with the
-- SHIPPED defaults (`on_error: return_tokenized`, and the empty-mapping bail),
-- so this is not an edge case.
--
-- Deliberately does NOT re-identify: callers use it precisely when
-- re-identification could not happen. Tokenized text is safe to deliver -- a
-- token is not PII -- and a readable answer containing `[NAME_x]` beats a stall.
-- Returns true if it emitted, so callers can tell a handled bail from a no-op.
local function reemit_tokenized_stream(ctx)
  if not ctx.client_stream then return false end
  local raw = kong.service.response.get_raw_body()
  if not raw or raw == "" then return false end
  if inflate_gzip and (kong.service.response.get_header("Content-Encoding") or ""):find("gzip", 1, true) then
    local ok_inf, inflated = pcall(inflate_gzip, raw)
    if ok_inf and inflated then raw = inflated end
  end
  local doc = body_json.decode(raw)
  if not doc then return false end
  local ok_sse, sse = pcall(doc_to_sse, doc, ctx.want_usage_chunk)
  if not ok_sse or not sse or sse == "" then return false end
  kong.response.set_raw_body(sse)
  kong.response.clear_header("Content-Encoding")
  kong.response.set_header("Content-Type", "text/event-stream")
  kong.response.set_header("Content-Length", #sse)
  kong.log.warn("skyflow: re-identification skipped; re-emitting the TOKENIZED ",
                "response as SSE so the streaming client does not stall")
  return true
end

function SkyflowAIDataControl:response(conf)
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
  -- Each bail below must still convert the stream we downgraded. See
  -- reemit_tokenized_stream: returning early here used to ship JSON under
  -- `Content-Type: text/event-stream`.
  if strat == "mapping_only" then
    if not next(by_token) then reemit_tokenized_stream(ctx); return end
  elseif not ctx.deidentified then
    reemit_tokenized_stream(ctx)
    return
  end

  local status = kong.service.response.get_status()
  if not status or status < 200 or status >= 300 then
    -- An upstream error body is JSON, and doc_to_sse would mangle it into a
    -- content-bearing message. Leave the body alone but drop the streaming
    -- content type we no longer honour, so the client parses it as the error it
    -- is instead of as a broken event stream.
    if ctx.client_stream then
      kong.response.set_header("Content-Type", "application/json")
    end
    return
  end

  -- reidentify_text calls the vault; resolve auth + a fresh deadline up front
  -- (deadline first: SA bearer minting is itself deadline-bounded).
  local authz, deadline
  if strat == "reidentify_text" then
    deadline = request_deadline(conf)
    local aerr, akind
    authz, aerr, akind = auth_value(conf, deadline)
    if not authz then
      -- Same 401/502 split as the request leg. Reaching here with an identity
      -- failure means the caller's token expired DURING generation -- rare, but
      -- a long response makes it possible, and "sign in again" is the honest
      -- answer rather than blaming Skyflow.
      if akind == "identity" then
        kong.log.warn("skyflow: caller identity rejected on the response leg: ", aerr)
        if conf.reidentify.on_error == "deny" then
          return kong.response.exit(401, { message = "response blocked: " .. tostring(aerr) })
        end
        reemit_tokenized_stream(ctx)
        return
      end
      kong.log.err("skyflow re-identify auth error: ", aerr)
      if conf.reidentify.on_error == "deny" then
        return kong.response.exit(502, { message = "response blocked: re-identify unavailable" })
      end
      reemit_tokenized_stream(ctx)
      return
    end
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
  --
  -- An UNMATCHED token is not an error here: the model mangled a placeholder we
  -- issued, so the vault cannot resolve it. Return the text as-is -- it is still
  -- tokenized, therefore still safe to deliver -- and count it, so a rising
  -- number is visible in the flow log instead of silently degrading quality.
  -- Every OTHER failure still propagates and the on_error gate applies.
  local unmatched = 0
  local function restore(text)
    if strat == "reidentify_text" then
      local out, err, kind = skyflow_reidentify(conf, authz, text, deadline)
      if not out and kind == "unmatched_token" then
        unmatched = unmatched + 1
        kong.log.warn("skyflow: leaving a span tokenized -- the vault could not ",
                      "resolve a token in it (the model most likely reformatted ",
                      "it); delivering the response anyway")
        return text
      end
      return out, err
    end
    return reidentify_string(text, by_token, treatment_fn)
  end

  local call_err
  local ok, perr = pcall(function()
    local raw = kong.service.response.get_raw_body()
    local ct  = kong.service.response.get_header("Content-Type")
    local enc = kong.service.response.get_header("Content-Encoding")
    -- Every "couldn't re-identify" path below sets call_err so the on_error
    -- gate applies uniformly -- fail-closed (deny) must not silently forward a
    -- tokenized body just because we couldn't read/parse it.
    if not raw or raw == "" then
      call_err = "no buffered response body"; return
    end

    -- Inflate gzip so the body is parseable. We emit the re-identified body
    -- UNcompressed and drop Content-Encoding (identity is always acceptable to
    -- a client that offered gzip), which avoids having to re-compress.
    local body, was_encoded = raw, false
    if enc and enc ~= "" then
      if enc:lower():find("gzip", 1, true) and inflate_gzip then
        local iok, dec = pcall(inflate_gzip, raw)
        if not iok or not dec then
          call_err = "gzip inflate failed"; return
        end
        body, was_encoded = dec, true
      else
        call_err = "unsupported Content-Encoding '" .. enc .. "'"; return
      end
    end

    local newbody
    local streamed = false
    if wants_json(conf, ct) then
      local doc = body_json.decode(body)
      if doc == nil then
        call_err = "response body not decodable JSON"; return
      end
      -- Tool inputs (OpenAI tool_calls / Anthropic tool_use). The policy is
      -- decided PER CALL by tool_policy(), because the right answer depends on
      -- where that particular tool sends its arguments:
      --   tokenized  -- leave the model's tokens in place. Correct when the tool
      --     fans data out past the gateway (web search, Slack, a remote API):
      --     real values must only materialize on authorized egress, and a tool
      --     handed a token simply no-ops.
      --   plain_text -- restore real values before the agent runs the tool.
      --     Correct when the tool executes on the caller's own machine, where
      --     leaving tokens is actively harmful: an `Edit` call carrying
      --     `[NAME_X2A0iim]` writes that token into the user's real file.
      -- collect_spans only covers message content, so this needs its own pass.
      local tool_changed = false

      if doc.choices then
        for _, ch in ipairs(doc.choices) do
          local tcs = ch.message and ch.message.tool_calls
          if type(tcs) == "table" then
            for _, tc in ipairs(tcs) do
              local fn = tc["function"]
              if fn and type(fn.arguments) == "string" and fn.arguments ~= ""
                 and tool_policy(conf, fn.name) == "plain_text" then
                local restored, rerr = restore(fn.arguments)
                if not restored then call_err = rerr; return end
                fn.arguments = restored
                tool_changed = true
              end
            end
          end
        end
      end

      -- Anthropic-native messages: same per-call policy, tool_use.input form.
      if is_anthropic_message(doc) then
        for _, block in ipairs(doc.content) do
          if block.type == "tool_use" and block.input ~= nil
             and tool_policy(conf, block.name) == "plain_text" then
            local enc = body_json.encode(block.input)
            if enc and enc ~= "" then
              local restored, rerr = restore(enc)
              if not restored then call_err = rerr; return end
              block.input = body_json.decode(restored) or block.input
              tool_changed = true
            end
          end
        end
      end

      local spans = collect_spans(doc, effective_paths(conf, "response"))
      if #spans == 0 and not tool_changed then
        -- Nothing to re-identify (e.g. an empty response). If the client is
        -- streaming we STILL must hand back SSE, not the raw JSON completion, or
        -- the client stalls waiting for event-stream frames.
        if not ctx.client_stream then return end
        newbody = doc_to_sse(doc, ctx.want_usage_chunk)
        streamed = true
      else
        for _, span in ipairs(spans) do
          if span.text ~= "" then
            local restored, rerr = restore(span.text)
            if not restored then call_err = rerr; return end
            span.parent[span.key] = restored
          end
        end
        newbody = body_json.encode(doc)
        -- Client asked to stream; re-emit the re-identified doc as SSE in the
        -- format the client's protocol expects (OpenAI chunk or Anthropic
        -- message events).
        if ctx.client_stream then
          newbody = doc_to_sse(doc, ctx.want_usage_chunk)
          streamed = true
        end
      end
    else
      local restored, rerr = restore(body)
      if not restored then call_err = rerr; return end
      newbody = restored
    end

    if newbody then
      kong.response.set_raw_body(newbody)
      if was_encoded then kong.response.clear_header("Content-Encoding") end
      if streamed then kong.response.set_header("Content-Type", "text/event-stream") end
      kong.response.set_header("Content-Length", #newbody)
    end
  end)

  if unmatched > 0 then
    kong.ctx.plugin.unmatched_tokens = unmatched
  end

  if (not ok) or call_err then
    -- Say what is actually about to happen. This message used to read
    -- "returning tokenized response" unconditionally and then 502 two lines
    -- later, which is how a response-destroying bug read as benign in the logs
    -- for a day.
    local detail = (not ok) and (": pcall: " .. tostring(perr))
                   or (call_err and (": " .. call_err) or "")
    if conf.reidentify.on_error == "deny" then
      kong.log.err("skyflow re-identify failed; WITHHOLDING the response (502)", detail)
      return kong.response.exit(502, { message = "response blocked: re-identify failed" })
    end
    kong.log.warn("skyflow re-identify failed; returning the TOKENIZED response", detail)
    -- ...and it has to be a STREAM if that is what the client asked for. This
    -- path is the shipped default (`on_error: return_tokenized`), so without
    -- this the most likely failure mode was also a protocol violation.
    reemit_tokenized_stream(ctx)
  end
end

function SkyflowAIDataControl:log(conf)
  if conf.log and conf.log.detections then
    local ctx = kong.ctx.plugin
    kong.log.set_serialize_value("skyflow.entities_by_type", ctx.entities_by_type or {})
    kong.log.set_serialize_value("skyflow.posture", ctx.posture or "enforce")
    -- Spans delivered still tokenized because the vault could not resolve a
    -- token the model had reformatted. Emitted only when non-zero, so it reads
    -- as a signal rather than noise -- a rising rate means the preamble is
    -- losing and response quality is degrading quietly.
    if ctx.unmatched_tokens then
      kong.log.set_serialize_value("skyflow.unmatched_tokens", ctx.unmatched_tokens)
    end
  end
end

-- Exposed for offline unit testing of the pure algorithms (no Kong runtime).
SkyflowAIDataControl._test = {
  bearer_token_value = bearer_token_value,
  build_ctx = build_ctx,
  auth_value = auth_value,
  parse_path        = parse_path,
  collect_spans     = collect_spans,
  effective_paths   = effective_paths,
  tool_policy       = tool_policy,
  classify_client_error = classify_client_error,
  doc_to_sse        = doc_to_sse,
  collect_media     = collect_media,
  run_waves         = run_waves,
  -- the codec the request/response bodies actually go through. Exported because
  -- asserting on the cjson LIBRARY instead of on this is what let the
  -- `tools: [] -> {}` bug pass a test written specifically for it.
  decode_body       = function(s) return body_json.decode(s) end,
  encode_body       = function(v) return body_json.encode(v) end,
  mask              = mask,
  plain_replace     = plain_replace,
  reidentify_string = reidentify_string,
  sse_chunk         = sse_chunk,
  is_anthropic_message     = is_anthropic_message,
  anthropic_message_to_sse = anthropic_message_to_sse,
  b64url_encode     = b64url_encode,
  b64url_decode     = b64url_decode,
  jwt_exp           = jwt_exp,
  precheck_caller_token = precheck_caller_token,
  inject_token_preamble = inject_token_preamble,
  DEFAULT_TOKEN_PREAMBLE = DEFAULT_TOKEN_PREAMBLE,
}

return SkyflowAIDataControl
