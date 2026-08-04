# Kong data plane that receives the plugin CODE from Konnect, not from this image.
#
#   docker build -f deploy/streaming/Dockerfile -t <tag> .
#
# The plugin is NOT baked in. schema.lua AND handler.lua are uploaded once to the
# control plane and streamed to every data plane over the cluster connection:
#
#   POST /v2/control-planes/{cp}/core-entities/custom-plugins
#     { "name": ..., "schema": <schema.lua>, "handler": <handler.lua> }
#
# Why this exists: it is the ONLY way a custom Lua plugin can run on a gateway
# whose image you do not control -- i.e. Konnect Dedicated Cloud Gateways -- and
# it turns plugin updates into an API call instead of a build-push-deploy cycle.
#
# THREE settings make it work, and two of them are non-obvious:
#
#   KONG_CUSTOM_PLUGIN_STREAMING_ENABLED=on
#     Required, defaults to off. Without it the control plane strips streamed
#     plugins from the config and reports issue P309, and the node keeps serving
#     its LAST GOOD config -- which for a privacy gateway can mean proxying with
#     no de-identification at all.
#
#   KONG_UNTRUSTED_LUA=lax
#     The one that actually blocked us. Streamed handler code runs in the
#     untrusted-Lua sandbox, which defaults to `strict`, and strict forbids
#     require(). The handler's very first lines are
#     `require "resty.http"` / `require "cjson.safe"`, so under strict the data
#     plane rejects the whole config with:
#         handler load failure ... require("resty.http") not allowed within sandbox
#     `lax` extends strict with "network related APIs and modules" -- exactly what
#     an HTTP-calling plugin needs -- and is preferred over `on`, which removes
#     the sandbox entirely. Measured: strict FAILS, lax WORKS, on WORKS.
#     `sandbox` + KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES also FAILS despite the
#     documentation saying that is what the allowlist is for.
#
#   KONG_PLUGINS=bundled  -- must NOT name skyflow-ai-data-control
#     Listing it makes Kong demand the code locally at boot ("plugin is enabled
#     but not installed") and the node dies before the stream ever arrives.
#     Streamed plugins are discovered from the control-plane config instead.
#
# Konnect also constrains the code itself: no per-entity custom validation
# function in schema.lua (the upload substring-matches for those names, so even a
# comment mentioning them fails), and no DAOs, migrations or extra modules --
# hence the single self-contained handler.
#
# This is the only supported data-plane build. An earlier variant baked the
# plugin into the image; it was removed, because an image containing our Lua is
# an image the customer has to rebuild to take a plugin update.

FROM kong/kong-gateway:3.15.0.2

ENV KONG_ROLE=data_plane \
    KONG_DATABASE=off \
    KONG_KONNECT_MODE=on \
    KONG_VITALS=off \
    KONG_CLUSTER_MTLS=pki \
    KONG_CUSTOM_PLUGIN_STREAMING_ENABLED=on \
    KONG_UNTRUSTED_LUA=lax \
    KONG_PLUGINS=bundled \
    KONG_PROXY_LISTEN=0.0.0.0:8000 \
    KONG_ADMIN_LISTEN=off \
    KONG_STATUS_LISTEN=off \
    KONG_LOG_LEVEL=info \
    KONG_PROXY_ERROR_LOG=/dev/stderr \
    KONG_PROXY_ACCESS_LOG=/dev/stdout \
    KONG_LUA_SSL_TRUSTED_CERTIFICATE=system

# Sized to Claude Desktop's own 32MB ceiling; see deploy/streaming/Dockerfile.
ENV KONG_NGINX_HTTP_CLIENT_BODY_BUFFER_SIZE=32m \
    KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE=32m

EXPOSE 8000
ENTRYPOINT ["/entrypoint.sh"]
CMD ["kong", "docker-start"]
