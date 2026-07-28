-- kong.plugins.skyflow-deidentify.schema
--
-- Konnect Dedicated Cloud Gateways build.
--
-- Konnect custom-plugin upload constraints honored here:
--   * NO `require()` statements (typedefs are inlined below).
--   * Self-contained: custom_entity_check fns use only the entity table + basic
--     Lua (no os.*, no globals, no requires).
--   * Pairs with a self-contained handler.lua; no extra modules/DAOs/migrations.
--
-- See docs/contributing/plugin-spec.md §4.3 for the field reference and docs/using/operations.md for the
-- Konnect upload steps.

local TOKEN_FORMATS = { "VAULT_TOKEN", "ENTITY_ONLY", "ENTITY_UNQ_COUNTER" }
local PROFILES      = { "openai", "anthropic", "mcp", "generic" }
local ENVS          = { "PROD", "SANDBOX", "DEV", "STAGE" }
local TREATMENTS    = { "plain_text", "masked", "redacted" }
-- mapping_only is the strategy implemented in this build; reidentify_text /
-- detokenize are accepted but degrade to return_tokenized until implemented
-- (see handler.lua / docs/contributing/skyflow-integration.md §3.5).
local STRATEGIES    = { "mapping_only", "reidentify_text", "detokenize" }
-- 'reassemble' streaming is a self-managed-only future option; omitted here so
-- it cannot be selected on the cloud build (avoids os.* in schema validation).
local STREAMING     = { "buffer", "passthrough" }
local PROTOCOLS     = { "http", "https", "grpc", "grpcs", "ws", "wss" }

-- Exactly one of api_key | token | service_account_json.
--   * service_account_json: full Skyflow SA credentials JSON; the handler
--     mints RS256 JWT-bearer tokens from it (cached per SA/scope/ctx).
--   * role_ids: scoped tokens -- restrict the bearer to a subset of the SA's
--     roles ("role:<id>" scope on the token exchange).
--   * ctx claim (context-aware authorization): Skyflow accepts arbitrary JSON
--     (vault policies traverse it as $ctx.a.b). Assembled in layers, later
--     layers winning:
--       context_json    -- raw JSON string, any shape; the ctx base
--       context         -- static attr(.path) -> string; dot-paths nest
--       context_headers -- attr(.path) -> request header (client-supplied)
--       context_kong    -- attr(.path) -> gateway-derived fact (trusted,
--                          merged last so clients can never override it)
local KONG_CTX_SOURCES = {
  "consumer_id", "consumer_username", "consumer_custom_id",
  "route_name", "service_name", "client_ip",
}

local credentials = {
  type = "record",
  required = true,
  fields = {
    { api_key = { type = "string", referenceable = true, encrypted = true } },
    { token   = { type = "string", referenceable = true, encrypted = true } },
    { service_account_json = { type = "string", referenceable = true, encrypted = true } },
    { role_ids = { type = "array", elements = { type = "string" } } },
    { context_json = { type = "string", referenceable = true, encrypted = true } },
    { context  = { type = "map", keys = { type = "string" }, values = { type = "string" } } },
    { context_headers = { type = "map", keys = { type = "string" }, values = { type = "string" } } },
    { context_kong = { type = "map", keys = { type = "string" },
                       values = { type = "string", one_of = KONG_CTX_SOURCES } } },
  },
  entity_checks = {
    { only_one_of = { "api_key", "token", "service_account_json" } },
    -- role_ids/context* shape the minted bearer; with a static api_key/token
    -- they would be silently ignored -- reject that config.
    { custom_entity_check = {
        field_sources = { "service_account_json", "role_ids", "context_json",
                          "context", "context_headers", "context_kong" },
        fn = function(entity)
          local has_sa = type(entity.service_account_json) == "string"
                         and entity.service_account_json ~= ""
          local function nonempty(t) return type(t) == "table" and next(t) ~= nil end
          local uses_sa_opts =
            (type(entity.role_ids) == "table" and #entity.role_ids > 0)
            or (type(entity.context_json) == "string" and entity.context_json ~= "")
            or nonempty(entity.context)
            or nonempty(entity.context_headers)
            or nonempty(entity.context_kong)
          if uses_sa_opts and not has_sa then
            return nil, "role_ids/context_json/context/context_headers/context_kong "
                        .. "require credentials.service_account_json"
          end
          -- Cheap shape check; full JSON validation happens at runtime (and
          -- fails closed). Skip when the value is a {vault://...} reference.
          if type(entity.context_json) == "string" and entity.context_json ~= ""
             and not entity.context_json:match("^%s*{") then
            return nil, "context_json must be a JSON object (or a secret reference)"
          end
          return true
        end,
    } },
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
    { strategy = { type = "string", one_of = STRATEGIES, default = "mapping_only" } },
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
    -- protocols (inlined; equivalent to typedefs.protocols_http)
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
          -- SA-JWT bearers are re-minted this many seconds before their exp.
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

          { conditional = {
              if_field = "reidentify.strategy", if_match = { eq = "mapping_only" },
              then_field = "deidentify.token_format", then_match = { ne = "ENTITY_ONLY" },
          } },

          -- Vault-authoritative re-id can only resolve tokens that were actually
          -- stored in the vault, i.e. VAULT_TOKEN de-identification.
          { conditional = {
              if_field = "reidentify.strategy", if_match = { eq = "reidentify_text" },
              then_field = "deidentify.token_format", then_match = { eq = "VAULT_TOKEN" },
          } },

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
        },
    } },
  },
}
