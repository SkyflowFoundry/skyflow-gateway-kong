-- Schema validation unit tests for skyflow-deidentify.
-- Run with busted (via Pongo): `pongo run spec/skyflow-deidentify/01-schema_spec.lua`
-- Mirrors docs/contributing/testing.md §6.3 and the entity checks in docs/contributing/plugin-spec.md §4.3.7.

local PLUGIN_NAME = "skyflow-deidentify"

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
    credentials = { api_key = "sky-test-key" },
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

  describe("credentials (exactly one of)", function()
    it("rejects when none provided", function()
      local c = base(); c.credentials = {}
      assert.is_falsy(validate(c))
    end)

    it("rejects when two provided", function()
      local c = base()
      c.credentials = { api_key = "k", token = "t" }
      assert.is_falsy(validate(c))
    end)

    it("accepts service_account_json alone", function()
      local c = base()
      c.credentials = { service_account_json = '{"clientID":"x"}' }
      assert.is_truthy(validate(c))
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

  it("requires paths/text for the generic profile", function()
    local c = base()
    c.profile = "generic"      -- no request_json_paths, content_type=auto
    assert.is_falsy(validate(c))

    c.content_type = "text"     -- text whole-body is acceptable
    assert.is_truthy(validate(c))
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
end)
