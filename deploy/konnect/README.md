# Konnect-managed control plane

The gateway runs as a **Kong data plane** attached to a Konnect control plane.
Konnect owns the configuration; this repo owns the plugin code and the config
*source*, which is synced with decK rather than rendered at boot.

```text
  kong.yaml (in git)  ──deck gateway sync──►  Konnect control plane
                                                      │ config over :443
  App Runner ◄── plugin baked into image ──────────────┘
```

## What lives where

| | Owner |
| --- | --- |
| Plugin **code** (`handler.lua`, `schema.lua`) | baked into the image — Konnect distributes plugin *config*, never code |
| Plugin **schema** | uploaded to the control plane so Konnect can validate `skyflow-deidentify` config |
| Routes, services, plugin config | `kong.yaml`, synced with decK |
| Provider keys | Secrets Manager → `{vault://env/…}`, resolved **on the data plane**; never sent to Konnect |
| Cluster keypair | generated locally, public half pinned to the CP, private half in Secrets Manager |

## Why the plugin is two self-contained files

Konnect's custom-plugin constraints, not preference: `schema.lua` must contain no
`require()` statements and custom validators must be self-contained in it, and
there may be no `api.lua`, `dao.lua`, or `migrations.lua`. Typedefs are therefore
inlined in `schema.lua`. Dedicated Cloud Gateways add a 100 KB per-file limit —
worth watching, since `handler.lua` is already ~69 KB.

## Setup

```bash
export KONNECT_TOKEN=kpat_…            # Konnect → Personal Access Tokens
CP_REGION=us                            # sets the api/cp/tp hostnames

# 1. a HYBRID control plane. A serverless one cannot take self-managed data
#    planes or custom plugins.
curl -s -X POST https://$CP_REGION.api.konghq.com/v2/control-planes \
  -H "Authorization: Bearer $KONNECT_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"skyflow-kong-gateway","cluster_type":"CLUSTER_TYPE_CONTROL_PLANE",
       "auth_type":"pinned_client_certs"}'
# keep: id, config.control_plane_endpoint, config.telemetry_endpoint

# 2. register the plugin schema — do this BEFORE any sync, or validation of the
#    skyflow-deidentify config fails
cd plugin/kong/plugins/skyflow-deidentify
curl -s -X POST \
  https://$CP_REGION.api.konghq.com/v2/control-planes/$CP/core-entities/plugin-schemas \
  -H "Authorization: Bearer $KONNECT_TOKEN" -H 'Content-Type: application/json' \
  --data "{\"lua_schema\": $(jq -Rs . ./schema.lua)}"

# 3. data-plane keypair. The private key never leaves your side.
openssl req -new -x509 -nodes -newkey rsa:2048 -sha256 -days 1095 \
  -subj "/CN=skyflow-kong-dp" -keyout tls.key -out tls.crt
curl -s -X POST \
  https://$CP_REGION.api.konghq.com/v2/control-planes/$CP/dp-client-certificates \
  -H "Authorization: Bearer $KONNECT_TOKEN" -H 'Content-Type: application/json' \
  --data "$(jq -n --rawfile c tls.crt '{cert:$c}')"

# 4. push the config. Always diff first.
deck gateway diff deploy/konnect/kong.yaml --konnect-control-plane-name skyflow-kong-gateway
deck gateway sync deploy/konnect/kong.yaml --konnect-control-plane-name skyflow-kong-gateway
```

Then build and deploy the data plane. `deploy/konnect/Dockerfile` sets every
`KONG_*` value that is a property of the *role*; only the endpoints and
credentials come from the environment:

| Variable | |
| --- | --- |
| `KONG_CLUSTER_CONTROL_PLANE` | `<id>.us.cp.konghq.com:443` |
| `KONG_CLUSTER_SERVER_NAME` | `<id>.us.cp.konghq.com` |
| `KONG_CLUSTER_TELEMETRY_ENDPOINT` | `<id>.us.tp.konghq.com:443` |
| `KONG_CLUSTER_TELEMETRY_SERVER_NAME` | `<id>.us.tp.konghq.com` |
| `KONG_CLUSTER_CERT` / `KONG_CLUSTER_CERT_KEY` | secrets — Kong accepts inline PEM |
| `ANTHROPIC_API_KEY`, `OPENAI_AUTH_HEADER` | secrets, for the `{vault://env/…}` refs |

## Verifying

```bash
curl -s https://us.api.konghq.com/v2/control-planes/$CP/nodes \
  -H "Authorization: Bearer $KONNECT_TOKEN" | jq '.items[] | {hostname, version, type}'

curl -s -o /dev/null -w '%{http_code}\n' https://<host>/healthz        # 200
curl -s https://<host>/claude/v1/messages -d '{…}'                     # 401 from the plugin
```

A `401` naming the missing caller identity token is the strongest cheap signal:
it proves the control plane delivered the config **and** that the custom plugin
loaded and ran.

## What changed versus the declarative deployment

`deploy/aws/` renders `kong-prod.template.yaml` at boot with `sed`, guarded by a
check that fails the container if any `__PLACEHOLDER__` survives. That path is
gone here — no `KONG_DECLARATIVE_CONFIG`, and a data plane that had one set would
refuse to start.

Config-as-code survives the move: `kong.yaml` stays in version control and
`deck gateway diff` replaces the boot-time guard, catching problems before a
deploy rather than during one.

Two notes worth keeping:

- **Self-hosting the data plane is load-bearing.** It is what lets us set
  `client_body_buffer_size=16m`. Konnect's own Dedicated Cloud Gateways don't
  allow that, and the nginx default of 8–16 KB would spool most real agent
  bodies to disk — where plugins are also forbidden from reading.
- **Konnect never sees a provider key.** `{vault://env/…}` references sync as
  literal strings and resolve on the data plane from Secrets Manager.
