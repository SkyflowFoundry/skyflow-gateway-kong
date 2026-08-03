# Kong data plane for a Konnect-managed control plane.
#
# Differs from deploy/aws/Dockerfile in one decisive way: there is NO declarative
# config and NO boot-time template rendering. The control plane is the source of
# truth and streams config over the cluster connection, so a data plane that also
# had KONG_DECLARATIVE_CONFIG set would refuse to start.
#
# The plugin IS baked into this image (COPY plugin /kong-plugins below), and the
# control plane holds only its SCHEMA, uploaded to:
#
#   PUT /v2/control-planes/{cp}/core-entities/plugin-schemas/skyflow-deidentify
#     { "name": ..., "lua_schema": <schema.lua> }
#
# Upload the schema BEFORE syncing a config that references a new field, or
# validation of the skyflow-deidentify config fails against the control plane.
#
# Kong 3.15 can also STREAM custom plugin code from the control plane via the
# `custom-plugins` endpoint, which would remove the need to bake it in. That was
# attempted and reverted, and everything below is why -- keep it here so the next
# person does not rediscover it:
#
#   * `custom_plugin_streaming_enabled` is REQUIRED and defaults to off. Without
#     it the control plane reports issue P309 -- "streaming custom plugins have
#     been removed from the config and the data plane may be inoperable" -- and
#     the node silently serves its last good config, which for a privacy gateway
#     means proxying with NO de-identification at all. Learned the hard way.
#   * `plugin-schemas` and `custom-plugins` are mutually exclusive: uploading to
#     custom-plugins fails while a plugin-schemas entry of the same name exists.
#   * With streaming, KONG_PLUGINS must NOT name the plugin -- listing it makes
#     Kong demand the code locally at boot ("skyflow-deidentify plugin is enabled
#     but not installed") and the node dies before the stream arrives. Because
#     the plugin is baked in here, KONG_PLUGINS DOES name it below. That is the
#     single line to change if streaming is revisited.
#
# The plugin still has to satisfy Konnect's custom-plugin constraints: no
# require() in schema.lua, no per-entity custom validation function (the upload
# substring-matches for those names, so even a comment mentioning them fails),
# and no DAOs/migrations/extra modules.
#
# Cluster credentials, provider keys, and the control-plane endpoints all arrive
# as environment variables at boot. This image carries no secrets and no IDs.
FROM kong/kong-gateway:3.15.0.2

USER root
COPY plugin /kong-plugins
RUN chown -R kong:kong /kong-plugins
USER kong

ENV KONG_ROLE=data_plane \
    KONG_DATABASE=off \
    KONG_KONNECT_MODE=on \
    KONG_VITALS=off \
    KONG_CLUSTER_MTLS=pki \
    KONG_PLUGINS=bundled,skyflow-deidentify \
    KONG_LUA_PACKAGE_PATH=/kong-plugins/?.lua;; \
    KONG_PROXY_LISTEN=0.0.0.0:8000 \
    KONG_ADMIN_LISTEN=off \
    KONG_STATUS_LISTEN=off \
    KONG_LOG_LEVEL=info \
    KONG_PROXY_ERROR_LOG=/dev/stderr \
    KONG_PROXY_ACCESS_LOG=/dev/stdout \
    KONG_LUA_SSL_TRUSTED_CERTIFICATE=system

# Sized to the CLIENT's ceiling, not a guess. Claude Desktop refuses a request
# over 32MB itself ("Accumulated images and attachments pushed the request over
# the limit"), so anything it will actually send must fit here. At 16m a request
# between 16 and 32MB was rejected by nginx before the plugin ever saw it, which
# the user experiences as an opaque gateway error on a request their client
# considered valid.
#
# Self-hosting the data plane is what lets us raise these at all -- they are NOT
# settable on Konnect's Dedicated Cloud Gateways, where the nginx default of
# 8-16KB would spool most real agent requests to disk.
ENV KONG_NGINX_HTTP_CLIENT_BODY_BUFFER_SIZE=32m \
    KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE=32m

EXPOSE 8000
# Kong's own entrypoint, deliberately: no rendering step to go wrong.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["kong", "docker-start"]
