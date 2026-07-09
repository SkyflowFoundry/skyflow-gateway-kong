-- Integration tests for the re-identify (response) path.
-- See docs/contributing/testing.md §6.4 / §6.5. Cases are `pending` until Phase 4 (docs/contributing/development.md) lands.

local helpers = require "spec.helpers"
local PLUGIN_NAME = "skyflow-deidentify"

for _, strategy in helpers.each_strategy() do
  describe(PLUGIN_NAME .. ": response (re-identify) [#" .. strategy .. "]", function()
    -- setup mirrors 02-access_spec but with reidentify.enabled = true and a
    -- mock upstream that returns assistant content containing tokens.

    pending("restores tokens in choices[*].message.content (reidentify_text)", function()
      -- entity_treatment: NAME=plain_text, CREDIT_CARD=masked, SSN=redacted
      -- assert name restored, card masked, ssn still redacted in client body
    end)

    pending("detokenize strategy restores targeted VAULT_TOKEN fields", function() end)

    pending("mapping_only performs NO second Skyflow call", function()
      -- assert the mock recorded zero /reidentify and zero /detokenize hits;
      -- tokens minted this request are restored; foreign tokens left intact
    end)

    pending("reidentify error -> return_tokenized yields a 200 (not 5xx)", function() end)
    pending("reidentify error -> deny yields the configured failure", function() end)

    pending("streaming=buffer: SSE response buffered, re-identified, returned whole", function() end)
    pending("streaming=passthrough: stream is NOT buffered or altered", function() end)

    pending("reidentify disabled imposes NO buffering (streaming still works)", function() end)

    -- Agent-traffic hardening (see demo/act2/README.md "What it took"). A real
    -- OpenAI client streams and uses tools; the gateway must buffer to
    -- re-identify, then re-emit as SSE. `sse_chunk` is unit-tested offline
    -- (spec/offline/pure_algorithms_test.lua); these assert the wired behavior.
    pending("client stream:true -> upstream forced non-stream, response re-emitted as SSE", function()
      -- Send stream:true. Assert: (a) upstream received stream:false (no SSE to
      -- re-identify across chunks); (b) client got Content-Type text/event-stream
      -- with a chat.completion.chunk data frame + a `data: [DONE]` sentinel;
      -- (c) the token in the answer was restored to its real value.
    end)
    pending("re-identifies tool_calls[*].function.arguments, not just content", function()
      -- Upstream returns a tool_call whose arguments string contains a token
      -- (e.g. a tokenized username in a file path). Assert the client sees the
      -- restored value in the arguments, so the agent acts on the real path.
    end)
    pending("skips empty content spans on re-id (tool_call response, content:null)", function()
      -- A tool_call completion has content null/absent (0 content spans). With a
      -- streaming client, assert it is still re-emitted as SSE rather than passed
      -- through as raw JSON (which would stall the client).
    end)

    -- Security invariants (docs/contributing/testing.md §6.5 / docs/using/security.md §7.7)
    pending("masked/redacted entities are NEVER returned in plaintext", function() end)
    pending("no fixture PII value appears in logs or metrics", function() end)
    pending("GET /plugins never returns raw credentials", function() end)
  end)
end
