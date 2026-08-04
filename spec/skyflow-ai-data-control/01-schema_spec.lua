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

    it("accepts SA-JWT options alongside service_account_json", function()
      local c = base()
      c.credentials = {
        service_account_json = '{"clientID":"x"}',
        role_ids = { "role-a", "role-b" },
        context_json = '{"org":{"id":"org_1"},"pci":true}',
        context  = { tenant = "acme", ["org.unit"] = "payments" },
        context_headers = { ["caller.user"] = "X-Consumer-Username" },
        context_kong = { ["caller.route"] = "route_name", ip = "client_ip" },
      }
      assert.is_truthy(validate(c))
    end)

    it("rejects a non-object context_json", function()
      local c = base()
      c.credentials = { service_account_json = '{"clientID":"x"}', context_json = "[1,2]" }
      assert.is_falsy(validate(c))
    end)

    it("rejects unknown context_kong sources", function()
      local c = base()
      c.credentials = { service_account_json = '{"clientID":"x"}',
                        context_kong = { user = "not_a_source" } }
      assert.is_falsy(validate(c))
    end)

    it("rejects context_json/context_kong without service_account_json", function()
      local c = base()
      c.credentials = { api_key = "k", context_json = '{"a":1}' }
      assert.is_falsy(validate(c))

      c = base()
      c.credentials = { api_key = "k", context_kong = { r = "route_name" } }
      assert.is_falsy(validate(c))
    end)

    it("rejects role_ids without service_account_json", function()
      local c = base()
      c.credentials = { api_key = "k", role_ids = { "role-a" } }
      assert.is_falsy(validate(c))
    end)

    it("rejects context/context_headers without service_account_json", function()
      local c = base()
      c.credentials = { token = "t", context = { tenant = "acme" } }
      assert.is_falsy(validate(c))

      c = base()
      c.credentials = { api_key = "k", context_headers = { user = "X-U" } }
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
