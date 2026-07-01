-- kong.plugins.skyflow-reidentify.schema
--
-- Response-phase re-identify plugin (pairs with skyflow-deidentify). Konnect
-- custom-plugin constraints honored: no require(), self-contained checks.

local ENVS      = { "PROD", "SANDBOX", "DEV", "STAGE" }
local PROFILES  = { "openai", "anthropic", "mcp", "generic" }
local PROTOCOLS = { "http", "https", "grpc", "grpcs", "ws", "wss" }

local credentials = {
  type = "record",
  required = true,
  fields = {
    { api_key = { type = "string", referenceable = true, encrypted = true } },
    { token   = { type = "string", referenceable = true, encrypted = true } },
    { service_account_json = { type = "string", referenceable = true, encrypted = true } },
    { role_ids = { type = "array", elements = { type = "string" } } },
    { context  = { type = "map", keys = { type = "string" }, values = { type = "string" } } },
  },
  entity_checks = {
    { only_one_of = { "api_key", "token", "service_account_json" } },
  },
}

return {
  name = "skyflow-reidentify",
  fields = {
    { protocols = {
        type = "set", required = true,
        default = { "grpc", "grpcs", "http", "https" },
        elements = { type = "string", one_of = PROTOCOLS },
    } },
    { config = {
        type = "record",
        fields = {
          ----------------------------------------------------------------- conn/auth
          { vault_id   = { type = "string", required = true } },
          { cluster_id = { type = "string", required = true } },
          { account_id = { type = "string" } },
          { env = { type = "string", one_of = ENVS, default = "PROD" } },
          { skyflow_base_url_override = { type = "string" } },
          { credentials = credentials },

          ----------------------------------------------------------------- targeting
          { profile = { type = "string", one_of = PROFILES, default = "openai" } },
          { response_json_paths = { type = "array", elements = { type = "string" }, default = {} } },
          { content_type = { type = "string", one_of = { "auto", "json", "text" }, default = "auto" } },

          ----------------------------------------------------------------- resilience
          { timeout_ms  = { type = "integer", default = 5000, between = { 100, 60000 } } },
          { deadline_ms = { type = "integer", default = 8000, between = { 100, 120000 } } },
          { retries = { type = "integer", default = 2, between = { 0, 5 } } },
          { keepalive_pool_size = { type = "integer", default = 16, between = { 0, 1000 } } },
          { keepalive_idle_ms = { type = "integer", default = 60000, between = { 0, 600000 } } },
          { on_error = { type = "string", one_of = { "return_tokenized", "deny" }, default = "return_tokenized" } },
        },

        entity_checks = {
          { custom_entity_check = {
              field_sources = { "timeout_ms", "deadline_ms" },
              fn = function(entity)
                if entity.deadline_ms and entity.timeout_ms
                   and entity.deadline_ms < entity.timeout_ms then
                  return nil, "deadline_ms must be >= timeout_ms"
                end
                return true
              end,
          } },
        },
    } },
  },
}
