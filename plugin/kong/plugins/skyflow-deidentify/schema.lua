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
    -- Profile B: exchange the CALLER's IdP token for a Skyflow bearer
    -- (RFC 8693 delegation). The gateway holds no Skyflow private key in this
    -- mode, and `ctx` comes entirely from the IdP's claims -- the
    -- context/context_headers/context_kong settings above do NOT apply,
    -- because Skyflow ignores context supplied in the exchange body. Put
    -- gateway-ish attributes (tenant, role, purpose) in the IdP token instead
    -- (e.g. Entra app roles or a claims-mapping policy); they then arrive
    -- IdP-signed rather than gateway-asserted.
    { sts = {
        type = "record",
        fields = {
          { enabled = { type = "boolean", default = false } },
          -- the Skyflow service account the caller is delegating through;
          -- must be listed in the account's STS configuration for the issuer
          { service_account_id = { type = "string" } },
          -- where the caller's token arrives (Claude Desktop's gateway OIDC
          -- mode sends it as `Authorization: Bearer <id_token>`)
          { token_header = { type = "string", default = "authorization" } },
          { token_uri = { type = "string",
                          default = "https://manage.skyflowapis.com/v1/auth/sts/token" } },
          -- local fail-fast checks; Skyflow still verifies the signature
          -- against the issuer's JWKS, so these are defense in depth
          { expected_issuer = { type = "string" } },
          { expected_audience = { type = "string" } },
        },
    } },
  },
  entity_checks = {
    -- NOT only_one_of: that requires *exactly* one, which would reject STS mode
    -- (Profile B carries no static credential -- the caller's IdP token is the
    -- credential). This check enforces "exactly one credential source" across
    -- all four options instead.
    { custom_entity_check = {
        field_sources = { "api_key", "token", "service_account_json", "sts" },
        fn = function(entity)
          local function set(v) return type(v) == "string" and v ~= "" end
          local n = 0
          if set(entity.api_key) then n = n + 1 end
          if set(entity.token) then n = n + 1 end
          if set(entity.service_account_json) then n = n + 1 end
          if entity.sts and entity.sts.enabled then n = n + 1 end
          if n == 0 then
            return nil, "exactly one credential is required: api_key, token, "
                        .. "service_account_json, or sts.enabled"
          end
          if n > 1 then
            return nil, "only one credential may be set: api_key, token, "
                        .. "service_account_json, or sts.enabled"
          end
          return true
        end,
    } },
    -- role_ids/context* shape the minted bearer; with a static api_key/token
    -- they would be silently ignored -- reject that config.
    { custom_entity_check = {
        field_sources = { "service_account_json", "role_ids", "context_json",
                          "context", "context_headers", "context_kong", "sts",
                          "api_key", "token" },
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
          local sts = entity.sts
          if sts and sts.enabled then
            if not (type(sts.service_account_id) == "string" and sts.service_account_id ~= "") then
              return nil, "credentials.sts.enabled requires sts.service_account_id"
            end
            if (type(entity.api_key) == "string" and entity.api_key ~= "")
               or (type(entity.token) == "string" and entity.token ~= "") then
              return nil, "credentials.sts.enabled cannot be combined with api_key/token"
            end
          end
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

-- Binary attachments (image / document content blocks). The text path cannot
-- touch base64 bytes, so without this they reach the provider unmodified.
--
--   mode=deidentify (default) -- send the file to Detect's V2 file API and
--     swap in the redacted bytes. Verified for png/jpg/gif/bmp/tif/pdf.
--   mode=strip        -- replace every attachment with a text marker
--   mode=block        -- refuse any request carrying an attachment
--   mode=passthrough  -- forward untouched (explicit opt-out; NOT the default,
--                        because silently forwarding what cannot be inspected
--                        is the one behaviour this plugin should never have)
--
-- `unsupported` covers formats Detect cannot process at all -- webp is the
-- notable one, since Anthropic accepts it and Detect does not -- plus URL and
-- file_id sources whose bytes the gateway never sees.
local MEDIA_MODES        = { "deidentify", "strip", "block", "passthrough" }
local UNSUPPORTED_MODES  = { "strip", "block" }
local MASKING_METHODS    = { "BLACKBOX", "BLUR" }
local PDF_MODES          = { "OCR", "TEXT_LAYER" }

local media = {
  type = "record",
  fields = {
    { mode = { type = "string", one_of = MEDIA_MODES, default = "deidentify" } },
    { unsupported = { type = "string", one_of = UNSUPPORTED_MODES, default = "strip" } },
    { masking_method = { type = "string", one_of = MASKING_METHODS, default = "BLACKBOX" } },
    -- Entity scope for attachments. Empty = ALL, which is intentionally
    -- broader than deidentify.entities: an image cannot be skimmed before it
    -- egresses, and ALL measurably detects more (6 vs 4 on a test card image).
    { entities = { type = "array", elements = { type = "string" }, default = {} } },
    -- Non-text objects to redact. MUST be specific types -- `ALL` blacks out
    -- every detected object including plain text runs, so the provider gets a
    -- solid black rectangle. FACE+SIGNATURE keeps the image legible while
    -- covering what entity detection cannot see.
    { redact_object_types = { type = "array",
                              elements = { type = "string",
                                           one_of = { "FACE", "SIGNATURE", "LOGO", "LICENSE_PLATE" } },
                              default = { "FACE", "SIGNATURE" } } },
    -- OCR rasterizes (right for scans); TEXT_LAYER edits the PDF's text layer
    -- and keeps it selectable.
    { pdf_processing_mode = { type = "string", one_of = PDF_MODES, default = "OCR" } },
    { poll_interval_ms = { type = "integer", default = 500, between = { 100, 5000 } } },
    -- Guard on base64 length. A PDF takes ~10s, so a large attachment can eat
    -- the whole request deadline; refuse early rather than time out mid-flight.
    { max_file_bytes = { type = "integer", default = 8388608, between = { 0, 67108864 } } },
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
    -- Tool inputs (tool_calls/tool_use) the model sends back to the agent:
    -- 'tokenized' (default) leaves tokens in place -- the gateway is the trust
    -- boundary and tools egress to arbitrary services; 'plain_text' restores
    -- real values first (trust-the-client deployments).
    { tool_inputs = { type = "string", one_of = { "tokenized", "plain_text" },
                      default = "tokenized" } },
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
          { media = media },
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
