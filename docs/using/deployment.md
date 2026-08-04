# Deployment

How to get `skyflow-ai-data-control` running on Kong. Pick the path that matches how
you run Kong, then configure the plugin ([operations.md](operations.md)) and
validate.

The plugin ships as two files — `schema.lua` and `handler.lua` — under
[`plugin/kong/plugins/skyflow-ai-data-control/`](../../plugin/kong/plugins/skyflow-ai-data-control).
That's all you upload or mount; there are no databases, migrations, or extra
modules.

## Choose your path

| You run Kong as… | Custom plugins? | Use |
| --- | --- | --- |
| **Self-managed / hybrid data plane** (you run the Kong container) | ✅ | Path A — mount the two files on your data plane |
| **Konnect Dedicated Cloud Gateways** (Konnect runs the data plane) | ✅ | Path B — upload the two files to the control plane |
| **Konnect Serverless** (free shared gateway) | ❌ not supported | Not available — use Path A for a free option |

## Path A — Self-managed / hybrid data plane (free)

Run a Kong data plane you control (standalone, or attached to a Konnect control
plane so you manage it from the Konnect UI). The plugin runs because the data
plane is yours.

- **Full step-by-step** (create a hybrid control plane, get the data-plane cert,
  start the container, upload the schema, sync config, demo):
  [`deploy/streaming/`](../../deploy/streaming).
- **Try it offline first**, no Konnect account or keys needed:
  [`test/offline-harness/`](../../test/offline-harness) brings up Kong + a mock
  Skyflow + a mock LLM and runs the full de-id → `ai-proxy` → re-id round-trip.

In short: mount the two files into the data plane and add them to `KONG_PLUGINS`:

```bash
# docker-compose (see test/offline-harness/docker-compose.yml)
KONG_PLUGINS: bundled,skyflow-ai-data-control
volumes:
  - ./plugin:/kong-plugins:ro
KONG_LUA_PACKAGE_PATH: /kong-plugins/?.lua;;
```

## Path B — Konnect Dedicated Cloud Gateways (paid, fully hosted)

Konnect runs the data plane for you, so you upload **both** files to the control
plane:

1. Control plane → **Plugins → Custom Plugins → New**.
2. Upload `schema.lua` **and** `handler.lua` from
   [`plugin/kong/plugins/skyflow-ai-data-control/`](../../plugin/kong/plugins/skyflow-ai-data-control).
3. Konnect validates the schema and distributes the plugin to the cloud data
   planes automatically.

> Hybrid (Path A) only needs `schema.lua` uploaded — the control plane uses it to
> validate config, while your data plane runs the mounted `handler.lua`.

## Configure the plugin

Attach `skyflow-ai-data-control` to a Route/Service with your Skyflow vault details.
See [operations.md](operations.md) for ready-to-copy decK, Admin API, KIC, and
Konnect config, including the nested-proxy layout for composing with `ai-proxy`.

Provide no Skyflow credential. STS delegation (RFC 8693) is the only credential path: the caller's enterprise IdP token is exchanged for a short-lived Skyflow bearer whose `ctx` is their signed claims. The gateway holds **no** Skyflow credential -- no API key, no service account, no private key -- so there is nothing here for an attacker who compromises the host to steal.
reidentify) permission — supply it as a secret reference such as
Configure `credentials.sts.service_account_id`, `expected_issuer` and `expected_audience` instead; none of them is a secret.

## Validate

Start in observe mode, then enforce:

```bash
# de-identify only: the provider should receive tokens; the client gets a normal answer
curl -i https://<your-gateway-host>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Email Jane Doe at jane@acme.com"}]}'
```

Confirm the upstream/provider received `[NAME_…]` / `[EMAIL_ADDRESS_…]` instead of
the real values. Set `dry_run: true` first to log detections without altering
traffic, then flip to enforcing — see the rollout playbook in
[operations.md](operations.md#rollout-playbook).
