-- LuaRocks packaging for the Skyflow De-identify Kong plugin.
-- Build: luarocks make
-- Pack:  luarocks pack skyflow-deidentify 0.1.0-1
-- Then enable in Kong: KONG_PLUGINS=bundled,skyflow-deidentify
--
-- NOTE: in this PoC repo the sources live under plugin/kong/plugins/...; the
-- module paths below assume promotion to the top-level kong/plugins/... path
-- (see docs/05 §5.1). Adjust module paths if you keep the plugin/ prefix.

package = "skyflow-deidentify"
version = "0.1.0-1"

source = {
  url = "git+https://github.com/SkyflowFoundry/skyflow-kong-poc.git",
  tag = "v0.1.0",
}

description = {
  summary  = "Kong plugin that de-identifies (and optionally re-identifies) request/response payloads via Skyflow Detect.",
  detailed = [[
    Sanitizes PII/PHI/secrets out of requests bound for LLM APIs, MCP servers,
    and other upstreams using Skyflow's Detect De-identify API, and optionally
    re-hydrates the original values into responses for authorized callers via
    Skyflow Re-identify / Detokenize. See the docs/ directory for the full spec.
  ]],
  homepage = "https://github.com/SkyflowFoundry/skyflow-kong-poc",
  license  = "Apache-2.0",
}

dependencies = {
  "lua >= 5.1",
  -- Provided by Kong/OpenResty at runtime; pinned for standalone installs:
  "lua-resty-http >= 0.17",
  -- ONLY needed when using service-account JWT auth. Prefer resty.openssl
  -- (bundled with modern Kong) for RS256 signing to drop this dependency.
  "lua-resty-jwt >= 0.2.3",
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins.skyflow-deidentify.handler"] = "kong/plugins/skyflow-deidentify/handler.lua",
    ["kong.plugins.skyflow-deidentify.schema"]  = "kong/plugins/skyflow-deidentify/schema.lua",
    ["kong.plugins.skyflow-deidentify.auth"]    = "kong/plugins/skyflow-deidentify/auth.lua",
    ["kong.plugins.skyflow-deidentify.client"]  = "kong/plugins/skyflow-deidentify/client.lua",
    ["kong.plugins.skyflow-deidentify.body"]    = "kong/plugins/skyflow-deidentify/body.lua",
    ["kong.plugins.skyflow-deidentify.mapping"] = "kong/plugins/skyflow-deidentify/mapping.lua",
  },
}
