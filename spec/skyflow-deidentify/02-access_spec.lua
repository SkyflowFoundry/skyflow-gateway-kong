-- Integration tests for the de-identify (request) path.
-- Real Kong (via Pongo + spec.helpers) pointed at the in-repo Skyflow mock.
-- See docs/contributing/testing.md §6.4 for the full case list. Cases are `pending` until the
-- corresponding implementation phase (docs/contributing/development.md) lands; the structure encodes
-- the acceptance criteria.

local helpers = require "spec.helpers"
local cjson   = require "cjson"

local PLUGIN_NAME = "skyflow-deidentify"

for _, strategy in helpers.each_strategy() do
  describe(PLUGIN_NAME .. ": access (de-identify) [#" .. strategy .. "]", function()
    local proxy_client
    local MOCK_SKYFLOW_URL  -- set to the mock fixture's URL in setup

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, { "routes", "services", "plugins" })

      -- Upstream "echo" service that records what it received (so tests can
      -- assert the upstream NEVER saw raw PII). Provided by helpers.mock_upstream.
      local service = bp.services:insert({ url = helpers.mock_upstream_url })
      local route = bp.routes:insert({
        service = service, paths = { "/v1/chat/completions" },
      })

      bp.plugins:insert({
        name = PLUGIN_NAME,
        route = route,
        config = {
          vault_id   = "vault123",
          cluster_id = "mock",
          skyflow_base_url_override = MOCK_SKYFLOW_URL,  -- point client at the mock
          credentials = { api_key = "sky-test" },
          profile = "openai",
          deidentify = { entities = { "NAME", "EMAIL_ADDRESS" }, token_format = "VAULT_TOKEN" },
          on_skyflow_error = "deny",
        },
      })

      assert(helpers.start_kong({
        plugins = "bundled," .. PLUGIN_NAME,
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }))
    end)

    lazy_teardown(function() helpers.stop_kong() end)
    before_each(function() proxy_client = helpers.proxy_client() end)
    after_each(function() if proxy_client then proxy_client:close() end end)

    local function chat(body)
      return proxy_client:post("/v1/chat/completions", {
        headers = { ["Content-Type"] = "application/json" },
        body = cjson.encode(body),
      })
    end

    pending("forwards a TOKENIZED body upstream (no raw PII reaches upstream)", function()
      local res = chat({ model = "gpt-4o", messages = {
        { role = "user", content = "Email Jane Doe at jane@acme.com" } } })
      assert.res_status(200, res)
      -- assert the echo upstream recorded tokens, not "Jane Doe"/"jane@acme.com"
    end)

    pending("fails CLOSED on Skyflow error (deny -> 502, upstream not called)", function()
      -- send header x-mock-fault: 500 (mock honors it); expect 502 + no upstream hit
    end)

    pending("fails OPEN when configured (allow -> original body forwarded + warn)", function() end)
    pending("dry_run leaves the body unchanged but logs detections", function() end)
    pending("denies/skip on non-JSON or oversized body per on_parse_error", function() end)
    pending("mcp profile tokenizes params.arguments.* string leaves only", function() end)
    pending("Content-Length is corrected after rewrite", function() end)

    -- Agent-traffic hardening (see demo/act2/README.md "What it took"). These
    -- paths only surface with real streaming, tool-using agents, not curls.
    pending("skips empty-string content spans (no Skyflow 400)", function()
      -- An assistant turn that only made tool calls carries content "". Skyflow
      -- Detect 400s on empty text, so the plugin must skip it, not fail the
      -- request. Send messages with a "" content span; expect 200, upstream hit.
    end)
    pending("reads a request body spooled to a temp file (large agent body)", function()
      -- A body larger than client_body_buffer_size makes get_raw_body() return
      -- nil; the plugin must fall back to ngx.req.get_body_file(). Send a body
      -- above the buffer size; expect it de-identified, not "body unavailable".
    end)
  end)
end
