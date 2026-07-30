# Kong data plane for a Konnect-managed control plane.
#
# Differs from deploy/aws/Dockerfile in one decisive way: there is NO declarative
# config and NO boot-time template rendering. The control plane is the source of
# truth and streams config over the cluster connection, so a data plane that also
# had KONG_DECLARATIVE_CONFIG set would refuse to start.
#
# What still has to be baked in: the plugin itself. Konnect distributes plugin
# *configuration*, never plugin *code* -- "All plugin files must also be deployed
# to each Kong Gateway Data Plane node." The schema is uploaded separately to the
# control plane so Konnect can validate config for `skyflow-deidentify`:
#
#   POST /v2/control-planes/{cp}/core-entities/plugin-schemas
#
# The plugin is two self-contained files with no require() in schema.lua, which
# is exactly what Konnect's custom-plugin constraints demand -- see
# plugin/kong/plugins/skyflow-deidentify/schema.lua.
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

# Agent bodies are large: tool schemas plus file contents. Self-hosting the data
# plane is what lets us raise these -- they are NOT settable on Konnect's own
# Dedicated Cloud Gateways, where the nginx default of 8-16 KB would spool most
# real requests to disk.
ENV KONG_NGINX_HTTP_CLIENT_BODY_BUFFER_SIZE=16m \
    KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE=16m

EXPOSE 8000
# Kong's own entrypoint, deliberately: no rendering step to go wrong.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["kong", "docker-start"]
