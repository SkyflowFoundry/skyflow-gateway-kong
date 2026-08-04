-- kong.plugins.skyflow-ai-data-control.schema
--
-- Konnect Dedicated Cloud Gateways build.
--
-- Konnect custom-plugin upload constraints honored here:
--   * NO `require()` statements (typedefs are inlined below).
--   * NO custom validation functions -- neither of Kong's two per-entity
--     escape hatches appears here. Konnect's plugin-streaming upload rejects a
--     schema containing them, and streaming is what lets the control plane
--     distribute this plugin's CODE rather than us baking it into every
--     data-plane image. Note the check is a SUBSTRING match on the schema text,
--     not a parse: even a comment naming those functions fails the upload, which
--     is why this note describes them instead. Rules that Kong's built-in entity
--     checkers cannot express live in handler.lua -- see entity_checks below.
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

-- How the plugin obtains a Skyflow bearer. Three methods, in descending order of
-- how strong a claim they make about WHO is asking:
--
--   sts             RFC 8693 token exchange. The caller's own IdP token is the
--                   credential; the gateway stores nothing. `ctx` is the IdP's
--                   signed claims.
--   jwt_credential  The gateway signs a service-account JWT (RS256) and exchanges
--                   it. The gateway holds a private key, and `ctx` is whatever the
--                   gateway asserts.
--   bearer_token    A long-lived Skyflow API key or bearer, sent as-is. No
--                   per-caller identity at all, and no `ctx`.
local AUTH_METHODS = { "sts", "jwt_credential", "bearer_token" }

-- WHY `ctx` DIFFERS BY METHOD -- the distinction that matters when choosing one:
--
--   sts            -- `ctx` IS available, but it is NOT configurable here.
--                     Skyflow silently ignores context supplied by the caller of
--                     an exchange, so ctx is exclusively the IdP's claims.
--                     Attributes like tenant, role and purpose belong in the IdP
--                     token (Entra app roles, claims-mapping policies), which is
--                     IdP-signed and strictly stronger than a gateway assertion.
--                     Configuring ctx under this method would be a no-op, so the
--                     ctx fields are not declared on this record at all -- the
--                     schema makes it unrepresentable rather than accepting it and
--                     letting an operator believe a policy is in force when it is
--                     not.
--   jwt_credential -- `ctx` is available AND configurable: the gateway mints the
--                     assertion, so it decides the claim set. This is the only
--                     method where context_json / context_headers / role_ids do
--                     anything.
--   bearer_token   -- no `ctx` and no per-caller identity. Every request looks
--                     identical to the vault, so vault policies keyed on
--                     `$ctx.<attr>` cannot discriminate. Present for gateways
--                     that already front their own authn and accept that
--                     trade-off; NOT the default.
local credentials = {
  type = "record",
  required = true,
  fields = {
    -- Defaults to `sts`: it is the only method where the gateway holds no Skyflow
    -- credential at all, so a compromised data plane yields nothing reusable.
    { method = { type = "string", one_of = AUTH_METHODS, default = "sts" } },

    { sts = {
        type = "record",
        fields = {
          -- The Skyflow service account the caller delegates through; it must be
          -- listed in the account's STS configuration for this issuer.
          --
          -- NOT `required = true` on the field itself. Kong materializes a record
          -- from its defaults even when the operator supplied none, so a required
          -- subfield here made the sts record effectively mandatory under EVERY
          -- method -- method=bearer_token failed with "in 'credentials': in
          -- 'service_account_id': required field missing". Requiredness is
          -- expressed per method in entity_checks below instead.
          { service_account_id = { type = "string" } },
          -- where the caller's token arrives (Claude Desktop's gateway OIDC mode
          -- sends it as `Authorization: Bearer <id_token>`)
          { token_header = { type = "string", default = "authorization" } },
          { token_uri = { type = "string",
                          default = "https://manage.skyflowapis.com/v1/auth/sts/token" } },
          -- local fail-fast checks; Skyflow still verifies the signature against
          -- the issuer's JWKS, so these are defense in depth and cost no network
          -- hop when a token is obviously for somewhere else
          { expected_issuer = { type = "string" } },
          { expected_audience = { type = "string" } },
        },
    } },

    -- Gateway-signed service-account JWT (RS256), exchanged for a Skyflow bearer.
    -- The gateway holds the private key, so this is a gateway-ASSERTED identity:
    -- weaker than STS, but it works when callers have no IdP token to delegate --
    -- service-to-service traffic, batch jobs, an internal client the gateway
    -- already authenticated by other means.
    { jwt_credential = {
        type = "record",
        fields = {
          -- the full service-account credentials JSON from Skyflow. Reference a
          -- vault entry rather than pasting it: {vault://env/SKYFLOW_SA_JSON}
          { service_account_json = { type = "string", referenceable = true } },
          -- ttl for the minted bearer; Skyflow caps this server-side
          { ttl_seconds = { type = "integer", default = 3600, between = { 60, 86400 } } },

          -- ctx machinery. Deliberately declared HERE and nowhere else: the
          -- schema itself is what makes ctx unsettable under sts and
          -- bearer_token, so no entity_check is needed and no operator can
          -- configure a claim set that would be silently discarded.
          { context_json = { type = "string" } },
          { context_headers = { type = "map", keys = { type = "string" },
                                values = { type = "string" }, default = {} } },
          { context_kong = { type = "boolean", default = false } },
          { role_ids = { type = "array", elements = { type = "string" }, default = {} } },
        },
    } },

    -- A long-lived Skyflow API key or bearer, forwarded as-is. No per-caller
    -- identity reaches the vault, so every request is attributed to this one
    -- credential and `$ctx.<attr>` policies cannot discriminate between callers.
    -- Choose it only when the gateway is the trust boundary and you accept that
    -- the audit trail names the gateway rather than a person.
    { bearer_token = {
        type = "record",
        fields = {
          { api_key = { type = "string", referenceable = true } },
          -- Skyflow expects `Authorization: Bearer <key>`; overridable for
          -- deployments fronting a proxy that renames the header.
          { header_name = { type = "string", default = "authorization" } },
          { scheme = { type = "string", one_of = { "Bearer", "ApiKey", "none" },
                       default = "Bearer" } },
        },
    } },
  },

  entity_checks = {
    -- Each method needs the ONE field it cannot work without. Targeting the inner
    -- field, not the record: Kong materializes a record from its defaults even
    -- when nothing was supplied, so `then_field = "bearer_token", required = true`
    -- passed against an auto-created empty record and a config naming a method
    -- with no credential in it validated cleanly -- the failure would then have
    -- surfaced as a runtime auth error on live traffic.
    { conditional = { if_field = "method", if_match = { eq = "sts" },
                      then_field = "sts.service_account_id",
                      then_match = { required = true } } },
    { conditional = { if_field = "method", if_match = { eq = "jwt_credential" },
                      then_field = "jwt_credential.service_account_json",
                      then_match = { required = true } } },
    { conditional = { if_field = "method", if_match = { eq = "bearer_token" },
                      then_field = "bearer_token.api_key",
                      then_match = { required = true } } },
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
    -- Explain the placeholders to the model. On by default: a model that has not
    -- been told what [NAME_a1b2c3] is tends to editorialise about redaction
    -- ("all names have been removed, so I cannot provide those details") instead
    -- of just using the placeholder -- which wastes a token the gateway would
    -- happily have re-identified on the way back. Set enabled=false to send the
    -- caller's prompt untouched, or `text` to replace the wording entirely.
    { token_preamble = {
        type = "record",
        fields = {
          { enabled = { type = "boolean", default = true } },
          { text    = { type = "string" } },
        },
    } },
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
    -- Per-tool override of the above, because one global setting is wrong in
    -- both directions for an agent harness. The destination of a tool call is
    -- what decides the policy, and the tool NAME is the only thing that reveals
    -- it -- Claude Desktop names MCP tools `mcp__<server>__<tool>` and built-ins
    -- bare (`Read`, `Edit`, `Bash`).
    --
    -- A tool that runs on the caller's own machine needs REAL values: left
    -- tokenized, an Edit call writes the vault token into the user's actual
    -- file, which is corruption rather than protection. A tool that ships its
    -- arguments to a third party (Slack, Gmail, web search) must stay tokenized
    -- or the gateway has been bypassed.
    --
    -- Keys are exact tool names, or a `*`-suffixed prefix (`mcp__workspace__*`).
    -- Exact beats prefix; longest prefix wins; no match falls back to
    -- `tool_inputs`. A map of plain strings on purpose: Konnect's custom-plugin
    -- validator rejects per-entity validation functions.
    { tool_inputs_by_tool = { type = "map", keys = { type = "string" },
                              values = { type = "string",
                                         one_of = { "tokenized", "plain_text" } },
                              default = {} } },
    { entity_treatment = { type = "map", keys = { type = "string" },
                           values = { type = "string", one_of = TREATMENTS }, default = {} } },
    { default_treatment = { type = "string", one_of = TREATMENTS, default = "plain_text" } },
    { streaming = { type = "string", one_of = STREAMING, default = "buffer" } },
    { on_error  = { type = "string", one_of = { "return_tokenized", "deny" }, default = "return_tokenized" } },
  },
}

return {
  name = "skyflow-ai-data-control",
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

        -- Only Kong's built-in entity checkers below -- no per-entity custom
        -- validation function, because the plugin-streaming upload refuses a
        -- schema that contains one. Two rules that used to live here needed
        -- arbitrary Lua and so moved into handler.lua:
        --   * deadline_ms >= timeout_ms is now CLAMPED at request time rather
        --     than rejected, which is strictly better -- a deadline shorter
        --     than one attempt's timeout is a typo, not an intent, and
        --     self-correcting beats refusing to boot.
        --   * profile 'generic' needing request_json_paths (or content_type
        --     text) is checked once per request and fails closed with the same
        --     message.
        entity_checks = {
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
        },
    } },
  },
}
