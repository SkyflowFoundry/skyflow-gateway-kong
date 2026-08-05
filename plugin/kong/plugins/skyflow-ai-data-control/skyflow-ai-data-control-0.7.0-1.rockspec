-- LuaRocks packaging for self-managed / local Kong installs.
--
-- NOTE: Konnect Dedicated Cloud Gateways do NOT use this rockspec. For Konnect
-- you upload the two self-contained files (schema.lua + handler.lua) to the
-- control plane directly (see docs/using/deployment.md). This rockspec is
-- for `luarocks make` on self-managed nodes and for local Docker testing.
--
-- Build: luarocks make
-- Enable in Kong: KONG_PLUGINS=bundled,skyflow-ai-data-control

package = "skyflow-ai-data-control"
version = "0.7.0-1"

source = {
  url = "git+https://github.com/SkyflowFoundry/skyflow-kong-poc.git",
  tag = "v0.7.0",
}

description = {
  summary  = "Kong plugin that de-identifies (and optionally re-identifies) request/response payloads via Skyflow Detect.",
  detailed = [[
    Sanitizes PII/PHI/secrets out of requests bound for LLM APIs, MCP servers,
    and other upstreams using Skyflow's Detect de-identify API, and restores the
    original values into responses so the caller sees real data while the provider
    never does. The wire format (OpenAI / Anthropic / MCP) is detected per request
    rather than configured. Packaged as two self-contained files (schema.lua +
    handler.lua) so it is also uploadable to Konnect Dedicated Cloud Gateways.
    See docs/ for the full spec.
  ]],
  homepage = "https://github.com/SkyflowFoundry/skyflow-kong-poc",
  license  = "Apache-2.0",
}

dependencies = {
  "lua >= 5.1",
  -- resty.http and cjson are provided by the Kong/OpenResty runtime; pinned
  -- here only for standalone (non-Kong) installs.
  "lua-resty-http >= 0.17",
  -- NOTE: no lua-resty-jwt, and none is needed. All three credential methods are
  -- served by the Kong/OpenResty runtime: the default STS exchange is a plain
  -- HTTPS call, and service-account JWT signing uses resty.openssl.pkey, which
  -- ships with the gateway and is on the streamed-plugin sandbox allowlist.
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins.skyflow-ai-data-control.handler"] = "kong/plugins/skyflow-ai-data-control/handler.lua",
    ["kong.plugins.skyflow-ai-data-control.schema"]  = "kong/plugins/skyflow-ai-data-control/schema.lua",
  },
}
