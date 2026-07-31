# Kong data plane WITHOUT a control plane: declarative config, rendered at boot.
#
# This is the fallback for running with no Konnect subscription. Build from the
# REPO ROOT, not from this directory:
#
#   docker build -f deploy/aws/Dockerfile -t <tag> .
#
# The paths below used to mix contexts -- `COPY plugin` needs the repo root while
# `COPY kong-prod.template.yaml` needed this directory -- so NEITHER context
# built, and the documented command failed with `"/plugin": not found`. All three
# COPYs are now repo-root relative, matching deploy/konnect/Dockerfile.
#
# LICENSING, unresolved and deliberately not papered over:
#
#   This is the ENTERPRISE image with no license. It runs -- Kong reports
#   `license type: free` -- but also prints:
#
#     "Kong Gateway is running in READ ONLY mode. Add a valid license to enable
#      all functionality. Configuration will not be loaded without a valid
#      license in a future release."
#
#   So this path works today and is a time bomb. The obvious fix is the OSS image,
#   and it was checked rather than assumed: `kong/kong:latest` is **3.9.3** -- six
#   minor versions behind the 3.15.0.2 this plugin is written and tested against
#   -- and there is no kong/kong:3.15 tag. Every plugin this config needs
#   (ai-proxy, pre-function, post-function, file-log, ip-restriction,
#   request-termination) IS present in 3.9.3, so the swap is plausible, but it is
#   a real downgrade and needs its own test pass. Get a license, or budget for
#   validating 3.9.
#
# The de-identification config in kong-prod.template.yaml is kept in lockstep
# with deploy/konnect/kong.yaml. Drift here is the dangerous kind: this file
# deploys cleanly and protects LESS. It previously lacked max_spans,
# max_concurrency and the whole tool_inputs_by_tool map.
FROM kong/kong-gateway:3.15.0.2
USER root
COPY plugin /kong-plugins
COPY deploy/aws/kong-prod.template.yaml /kong-prod.template.yaml
COPY deploy/aws/docker-entrypoint-prod.sh /docker-entrypoint-prod.sh
RUN chmod +x /docker-entrypoint-prod.sh && chown -R kong:kong /kong-plugins
USER kong
ENV KONG_DATABASE=off \
    KONG_PLUGINS=bundled,skyflow-deidentify \
    KONG_LUA_PACKAGE_PATH=/kong-plugins/?.lua;; \
    KONG_PROXY_LISTEN=0.0.0.0:8000 \
    KONG_LOG_LEVEL=info \
    KONG_PROXY_ERROR_LOG=/dev/stderr \
    KONG_PROXY_ACCESS_LOG=/dev/stdout \
    KONG_LUA_SSL_TRUSTED_CERTIFICATE=system \
    KONG_NGINX_HTTP_CLIENT_BODY_BUFFER_SIZE=16m \
    KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE=16m
EXPOSE 8000
ENTRYPOINT ["/docker-entrypoint-prod.sh"]
