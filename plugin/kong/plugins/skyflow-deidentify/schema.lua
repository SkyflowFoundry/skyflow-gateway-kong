-- kong.plugins.skyflow-deidentify.schema
--
-- Configuration contract for the Skyflow De-identify plugin.
-- See docs/04-plugin-spec.md §4.3 for the field-by-field reference.
--
-- This is the reference schema that realizes the spec. It is written to be
-- loadable by Kong; entity checks that rely on nested (dotted) field
-- references require Kong 3.x. Items that must be validated against a live
-- tenant are noted in docs/03-skyflow-integration.md.

local typedefs = require "kong.db.schema.typedefs"

local TOKEN_FORMATS = { "VAULT_TOKEN", "ENTITY_ONLY", "ENTITY_UNQ_COUNTER" }
local PROFILES      = { "openai", "anthropic", "mcp", "generic" }
local ENVS          = { "PROD", "SANDBOX", "DEV", "STAGE" }
local TREATMENTS    = { "plain_text", "masked", "redacted" }
local STRATEGIES    = { "reidentify_text", "detokenize", "mapping_only" }
local STREAMING     = { "buffer", "passthrough", "reassemble" }

-- credentials: exactly one of api_key | token | service_account_json.
-- All secret-bearing fields are referenceable (so `{vault://...}` works) and
-- marked encrypted so they are never returned in plaintext by the Admin API.
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

local shift_dates = {
  type = "record",
  fields = {
    { enabled  = { type = "boolean", default = false } },
    { min_days = { type = "integer", default = 10 } },
    { max_days = { type = "integer", default = 30 } },
    { entities = { type = "array", elements = { type = "string" }, default = { "DOB" } } },
  },
}

local deidentify = {
  type = "record",
  fields = {
    { entities = { type = "array", elements = { type = "string" }, default = {} } },
    { token_format = { type = "string", one_of = TOKEN_FORMATS, default = "VAULT_TOKEN" } },
    { allow_regex    = { type = "array", elements = { type = "string" }, default = {} } },
    { restrict_regex = { type = "array", elements = { type = "string" }, default = {} } },
    { shift_dates = shift_dates },
    { batch_mode = { type = "string", one_of = { "per_span", "joined" }, default = "per_span" } },
  },
}

local reidentify = {
  type = "record",
  fields = {
    { enabled  = { type = "boolean", default = false } },
    { strategy = { type = "string", one_of = STRATEGIES, default = "reidentify_text" } },
    { entity_treatment = { type = "map", keys = { type = "string" },
                           values = { type = "string", one_of = TREATMENTS }, default = {} } },
    { default_treatment = { type = "string", one_of = TREATMENTS, default = "plain_text" } },
    { streaming = { type = "string", one_of = STREAMING, default = "buffer" } },
    { on_error  = { type = "string", one_of = { "return_tokenized", "deny" }, default = "return_tokenized" } },
  },
}

return {
  name = "skyflow-deidentify",
  fields = {
    -- This plugin acts on HTTP-family protocols (and gRPC/WS where a JSON/text
    -- body applies). Stream (tcp/udp) is not applicable.
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          ----------------------------------------------------------------- conn/auth
          { vault_id   = { type = "string", required = true } },
          { cluster_id = { type = "string", required = true } },
          { account_id = { type = "string" } },
          { env = { type = "string", one_of = ENVS, default = "PROD" } },
          { skyflow_base_url_override = typedefs.url { required = false } },
          { credentials = credentials },
          { token_skew_seconds = { type = "integer", default = 300, between = { 0, 3600 } } },

          ----------------------------------------------------------------- targeting
          { profile = { type = "string", one_of = PROFILES, default = "openai" } },
          { request_json_paths  = { type = "array", elements = { type = "string" }, default = {} } },
          { response_json_paths = { type = "array", elements = { type = "string" }, default = {} } },
          { content_type = { type = "string", one_of = { "auto", "json", "text" }, default = "auto" } },
          { max_body_size = { type = "integer", default = 1048576, between = { 0, 33554432 } } },
          { max_spans = { type = "integer", default = 64, between = { 1, 4096 } } },

          ----------------------------------------------------------------- behavior
          { deidentify = deidentify },
          { reidentify = reidentify },

          ----------------------------------------------------------------- resilience
          { timeout_ms  = { type = "integer", default = 5000, between = { 100, 60000 } } },
          { deadline_ms = { type = "integer", default = 8000, between = { 100, 120000 } } },
          { retries = { type = "integer", default = 2, between = { 0, 5 } } },
          { max_concurrency = { type = "integer", default = 8, between = { 1, 64 } } },
          { keepalive_pool_size = { type = "integer", default = 16, between = { 0, 1000 } } },
          { keepalive_idle_ms = { type = "integer", default = 60000, between = { 0, 600000 } } },
          { on_skyflow_error = { type = "string", one_of = { "deny", "allow" }, default = "deny" } },
          { on_parse_error   = { type = "string", one_of = { "deny", "skip" }, default = "deny" } },
          { dry_run = { type = "boolean", default = false } },

          ----------------------------------------------------------------- observability
          { log = { type = "record", fields = {
              { detections = { type = "boolean", default = true } },
              { sample_rate = { type = "number", default = 1.0, between = { 0, 1 } } },
          } } },
          { metrics = { type = "record", fields = {
              { enabled = { type = "boolean", default = true } },
          } } },
        },

        entity_checks = {
          -- deadline must cover at least one attempt
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

          -- one-way tokens cannot be re-identified from the request mapping
          { conditional = {
              if_field = "reidentify.strategy", if_match = { eq = "mapping_only" },
              then_field = "deidentify.token_format", then_match = { ne = "ENTITY_ONLY" },
          } },

          -- generic profile needs explicit targeting (paths) unless treated as text
          { custom_entity_check = {
              field_sources = { "profile", "request_json_paths", "content_type" },
              fn = function(entity)
                if entity.profile == "generic"
                   and entity.content_type ~= "text"
                   and (not entity.request_json_paths or #entity.request_json_paths == 0) then
                  return nil, "profile 'generic' requires request_json_paths or content_type=text"
                end
                return true
              end,
          } },

          -- 'reassemble' streaming is experimental; gate behind an env opt-in
          { custom_entity_check = {
              field_sources = { "reidentify.streaming" },
              fn = function(entity)
                if entity.reidentify and entity.reidentify.streaming == "reassemble"
                   and os.getenv("SKYFLOW_ENABLE_REASSEMBLE") ~= "1" then
                  return nil, "reidentify.streaming='reassemble' is experimental; "
                              .. "set SKYFLOW_ENABLE_REASSEMBLE=1 to enable"
                end
                return true
              end,
          } },
        },
    } },
  },
}
