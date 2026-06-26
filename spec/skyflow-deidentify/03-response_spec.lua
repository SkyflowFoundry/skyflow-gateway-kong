-- Integration tests for the re-identify (response) path.
-- See docs/06 §6.4 / §6.5. Cases are `pending` until Phase 4 (docs/05) lands.

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

    -- Security invariants (docs/06 §6.5 / docs/07 §7.7)
    pending("masked/redacted entities are NEVER returned in plaintext", function() end)
    pending("no fixture PII value appears in logs or metrics", function() end)
    pending("GET /plugins never returns raw credentials", function() end)
  end)
end
