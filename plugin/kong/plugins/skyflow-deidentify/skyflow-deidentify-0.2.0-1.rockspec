-- LuaRocks packaging for self-managed / local Kong installs.
--
-- NOTE: Konnect Dedicated Cloud Gateways do NOT use this rockspec. For Konnect
-- you upload the two self-contained files (schema.lua + handler.lua) to the
-- control plane directly (see docs/09-konnect-deployment.md). This rockspec is
-- for `luarocks make` on self-managed nodes and for local Docker testing.
--
-- Build: luarocks make
-- Enable in Kong: KONG_PLUGINS=bundled,skyflow-deidentify

package = "skyflow-deidentify"
version = "0.2.0-1"

source = {
  url = "git+https://github.com/SkyflowFoundry/skyflow-kong-poc.git",
  tag = "v0.2.0",
}

description = {
  summary  = "Kong plugin that de-identifies (and optionally re-identifies) request/response payloads via Skyflow Detect.",
  detailed = [[
    Sanitizes PII/PHI/secrets out of requests bound for LLM APIs, MCP servers,
    and other upstreams using Skyflow's Detect De-identify API, and optionally
    re-hydrates the original values into responses. Packaged as two self-
    contained files (schema.lua + handler.lua) so it is also uploadable to
    Konnect Dedicated Cloud Gateways. See docs/ for the full spec.
  ]],
  homepage = "https://github.com/SkyflowFoundry/skyflow-kong-poc",
  license  = "Apache-2.0",
}

dependencies = {
  "lua >= 5.1",
  -- resty.http and cjson are provided by the Kong/OpenResty runtime; pinned
  -- here only for standalone (non-Kong) installs.
  "lua-resty-http >= 0.17",
  -- NOTE: no lua-resty-jwt. The single-file build uses API-key / static-token
  -- auth. Service-account JWT (RS256 via resty.openssl) is a documented
  -- follow-up and adds no new rock dependency.
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins.skyflow-deidentify.handler"] = "kong/plugins/skyflow-deidentify/handler.lua",
    ["kong.plugins.skyflow-deidentify.schema"]  = "kong/plugins/skyflow-deidentify/schema.lua",
  },
}
