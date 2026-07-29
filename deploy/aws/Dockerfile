FROM kong/kong-gateway:3.14
USER root
COPY plugin /kong-plugins
COPY kong-prod.template.yaml /kong-prod.template.yaml
COPY docker-entrypoint-prod.sh /docker-entrypoint-prod.sh
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
