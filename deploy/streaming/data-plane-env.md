# Data-plane settings

The plugin is **never added to your Kong image**. `handler.lua` and `schema.lua`
are uploaded to the control plane and streamed to every data plane at runtime, so
the image stays whatever it already was — verified bit-for-bit identical to
upstream `kong/kong-gateway:3.15.0.2`.

What you change is three environment variables on the deployment you already run.

| Variable | Value | Why |
| --- | --- | --- |
| `KONG_CUSTOM_PLUGIN_STREAMING_ENABLED` | `on` | Defaults to **off**. Without it the control plane strips streamed plugins from the config and reports issue **P309** — and the node keeps serving its last good config, which for a privacy gateway can mean proxying with no de-identification at all. Treat a P309 as an incident. |
| `KONG_UNTRUSTED_LUA` | `lax` | Streamed code is sandboxed. The default `strict` forbids `require()`, which this handler does on its first lines, so the data plane rejects the whole config. Measured on 3.15.0.2: `strict` fails, `lax` works, `on` works but drops the sandbox entirely. `sandbox` + `untrusted_lua_sandbox_requires` fails despite the docs. |
| `KONG_PLUGINS` | `bundled` | Must **not** name `skyflow-ai-data-control`, or Kong demands the code locally at boot and the node dies before the stream arrives. |

Set them however you already set environment variables:

```bash
# Docker
docker run -e KONG_CUSTOM_PLUGIN_STREAMING_ENABLED=on \
           -e KONG_UNTRUSTED_LUA=lax \
           -e KONG_PLUGINS=bundled \
           ... kong/kong-gateway:3.15.0.2

# Helm: values.yaml -> env:
#   custom_plugin_streaming_enabled: "on"
#   untrusted_lua: "lax"
#   plugins: "bundled"

# ECS / ECS Express: container `environment` entries
```

Optional, if clients send large prompts (Claude Desktop's own ceiling is 32 MB):

```
KONG_NGINX_HTTP_CLIENT_BODY_BUFFER_SIZE=32m
KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE=32m
```

## There is deliberately no Dockerfile here

An earlier version of this directory shipped one. It contained no `COPY`, `ADD`
or `RUN` — only `FROM kong/kong-gateway:3.15.0.2` and these `ENV` lines — so the
image it produced was byte-identical to upstream. It was removed anyway: a
Dockerfile in a directory called `deploy/` reads as "you must build an image",
which is the opposite of the point, and it invited people to maintain a derived
image for no gain.

Both live gateways run the **stock upstream image** with these variables set on
the container, which is the proof that no image work is needed.
