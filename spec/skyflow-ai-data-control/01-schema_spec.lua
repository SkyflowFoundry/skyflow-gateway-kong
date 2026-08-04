-- Schema validation unit tests for skyflow-ai-data-control.
-- Run with busted (via Pongo): `pongo run spec/skyflow-ai-data-control/01-schema_spec.lua`
-- Mirrors docs/contributing/testing.md §6.3 and the entity checks in docs/contributing/plugin-spec.md §4.3.7.

local PLUGIN_NAME = "skyflow-ai-data-control"

local validate
do
  local validate_entity = require("spec.helpers").validate_plugin_config_schema
  local schema = require("kong.plugins." .. PLUGIN_NAME .. ".schema")
  function validate(config)
    return validate_entity(config, schema)
  end
end

-- minimal valid config used as a base for each case
local function base()
  return {
    vault_id   = "vault123",
    cluster_id = "ebfc9bee",
    credentials = { sts = { service_account_id = "sa-test" } },
  }
end

describe(PLUGIN_NAME .. ": schema", function()
  it("accepts a minimal valid config", function()
    local ok, err = validate(base())
    assert.is_nil(err)
    assert.is_truthy(ok)
  end)

  it("requires vault_id and cluster_id", function()
    local c = base(); c.vault_id = nil
    local ok = validate(c)
    assert.is_falsy(ok)
  end)

  describe("credentials.method", function()
    -- The plugin used to be STS-only, then gained a `method` enum. These cases
    -- pin the two properties that matter and that a reader cannot infer from the
    -- field list: each method demands its own credential, and ctx is not
    -- configurable ANYWHERE.
    it("defaults to sts", function()
      local c = base()
      local entity = validate(c)
      assert.is_truthy(entity)
      assert.equals("sts", entity.credentials.method)
    end)

    it("rejects method=bearer_token without an api_key", function()
      local c = base()
      c.credentials = { method = "bearer_token", bearer_token = {} }
      assert.is_falsy(validate(c))
    end)

    it("accepts method=bearer_token with an api_key", function()
      local c = base()
      c.credentials = { method = "bearer_token", bearer_token = { api_key = "sky-k" } }
      assert.is_truthy(validate(c))
    end)

    it("rejects method=jwt_credential without service_account_json", function()
      local c = base()
      c.credentials = { method = "jwt_credential", jwt_credential = {} }
      assert.is_falsy(validate(c))
    end)

    it("accepts method=jwt_credential with only service_account_json", function()
      local c = base()
      c.credentials = { method = "jwt_credential",
                        jwt_credential = { service_account_json = '{"clientID":"x"}' } }
      assert.is_truthy(validate(c))
    end)

    it("rejects method=sts without a service_account_id", function()
      local c = base()
      c.credentials = { method = "sts", sts = {} }
      assert.is_falsy(validate(c))
    end)

    -- ctx is DERIVED by the handler (route, service, consumer, client IP,
    -- request id), never configured. context_headers in particular was removed
    -- because it fed caller-controlled headers into the claim set the vault
    -- trusts for policy decisions.
    it("rejects ctx configuration on jwt_credential", function()
      for _, field in ipairs({ "context_json", "context_headers", "context_kong",
                               "role_ids", "ttl_seconds" }) do
        local c = base()
        c.credentials = { method = "jwt_credential",
                          jwt_credential = { service_account_json = '{"clientID":"x"}' } }
        c.credentials.jwt_credential[field] = "x"
        assert.is_falsy(validate(c), field .. " must be rejected")
      end
    end)

    it("rejects a top-level api_key (it lives under bearer_token)", function()
      local c = base()
      c.credentials = { api_key = "sky-k" }
      assert.is_falsy(validate(c))
    end)
  end)

  it("rejects mapping_only with one-way ENTITY_ONLY tokens", function()
    local c = base()
    c.deidentify = { token_format = "ENTITY_ONLY" }
    c.reidentify = { enabled = true, strategy = "mapping_only" }
    assert.is_falsy(validate(c))
  end)

  it("rejects deadline_ms < timeout_ms", function()
    local c = base()
    c.timeout_ms  = 5000
    c.deadline_ms = 1000
    assert.is_falsy(validate(c))
  end)

  -- There is no `profile` field to validate: the wire format is detected per
  -- request from the body shape. The rule this case used to cover ("an
  -- unrecognised shape needs request_json_paths or content_type=text") moved
  -- into handler.lua, because the shape is not knowable at config time. Its
  -- replacement lives in spec/offline/pure_algorithms_test.lua section 24.
  it("rejects an unknown field where `profile` used to be", function()
    local c = base()
    c.profile = "openai"
    assert.is_falsy(validate(c))
  end)

  it("accepts referenceable secret credentials (vault://)", function()
    local c = base()
    c.credentials = { api_key = "{vault://env/SKYFLOW_API_KEY}" }
    assert.is_truthy(validate(c))
  end)

  it("validates enum fields", function()
    local c = base()
    c.deidentify = { token_format = "NOT_A_FORMAT" }
    assert.is_falsy(validate(c))
  end)

  describe("sts (Profile B)", function()
    it("accepts sts.enabled as the sole credential", function()
      local c = base()
      c.credentials = { sts = { enabled = true, service_account_id = "sa123",
                                expected_issuer = "https://login.microsoftonline.com/t/v2.0",
                                expected_audience = "client-id" } }
      assert.is_truthy(validate(c))
    end)

    it("requires a service_account_id when enabled", function()
      local c = base()
      c.credentials = { sts = { enabled = true } }
      assert.is_falsy(validate(c))
    end)

    it("rejects sts combined with another credential", function()
      local c = base()
      c.credentials = { api_key = "k", sts = { enabled = true, service_account_id = "sa123" } }
      assert.is_falsy(validate(c))
    end)

    it("still requires exactly one credential overall", function()
      local c = base()
      c.credentials = {}
      assert.is_falsy(validate(c))

      c = base()
      c.credentials = { api_key = "k", token = "t" }
      assert.is_falsy(validate(c))
    end)
  end)

  it("accepts tool_inputs treatments and rejects unknown values", function()
    local c = base()
    c.reidentify = { enabled = true, tool_inputs = "plain_text" }
    assert.is_truthy(validate(c))

    c = base()
    c.reidentify = { enabled = true, tool_inputs = "masked" }
    assert.is_falsy(validate(c))
  end)
end)
