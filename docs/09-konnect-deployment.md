# 09 — Konnect Dedicated Cloud Gateways Deployment

This is the chosen deployment target, and it constrains packaging. This doc
captures the constraints, the resulting code shape, and how to upload + run the
plugin.

## 9.1 Why packaging changed

Konnect tiers differ in custom-plugin support:

| Konnect tier | Custom Lua plugin? | Constraint |
| ------------ | ------------------ | ---------- |
| **Serverless** (free trial) | ❌ Not supported | Bundled plugins only — good for trying AI Proxy / AI PII Sanitizer, learning routes/plugins. |
| **Dedicated Cloud Gateways** | ✅ Supported, auto-distributed CP→DP | **Only `schema.lua` + `handler.lua`**, self-contained: no extra modules, no DAOs/migrations/custom APIs, and **`schema.lua` must contain no `require()`**. |
| **Self-managed / hybrid DP** | ✅ Full | Multiple modules + external rocks allowed. |

To meet the Dedicated Cloud Gateways rules, this PoC is packaged as **two
self-contained files**:

- `schema.lua` — **no `require()`**. The `typedefs` helpers were inlined
  (e.g. `protocols` is declared explicitly instead of `typedefs.protocols_http`,
  and `skyflow_base_url_override` is a plain string field). All `entity_checks`
  use only self-contained functions (no `os.*`, no globals).
- `handler.lua` — **all logic inlined**: auth, the Skyflow Detect client,
  JSONPath-lite body targeting, the request map, and re-identify. It requires
  only runtime-provided libs (`resty.http`, `cjson`).

The logical module decomposition in [`docs/02 §2.2`](02-architecture.md#22-module-decomposition)
still describes the design; it is simply physically consolidated into
`handler.lua` for this target. (If you also deploy to self-managed nodes, the
same two files work there via the [rockspec](../plugin/kong/plugins/skyflow-deidentify/skyflow-deidentify-0.2.0-1.rockspec).)

## 9.2 What's implemented vs. follow-up (this build)

| Capability | Status |
| ---------- | ------ |
| De-identify request bodies (Skyflow Detect) | ✅ implemented |
| Profiles openai / anthropic / mcp / generic + JSONPath-lite | ✅ implemented |
| Fail-closed/open posture, dry-run, size/span limits | ✅ implemented |
| Re-identify via `mapping_only` (no extra Skyflow call) | ✅ implemented |
| Re-identify via `reidentify_text` (vault-backed, `/v1/detect/reidentify/string`) | ✅ implemented |
| Auth: API key / static bearer token | ✅ implemented |
| Re-identify via `detokenize` (vault `/detokenize` API) | ⏳ follow-up (degrades to `return_tokenized` + warn) |
| Service-account JWT auth (RS256 via `resty.openssl`) | ⏳ follow-up |
| Per-span concurrency, streaming `reassemble` | ⏳ follow-up |

The pure algorithms (path targeting, masking, re-identify substitution) are
covered by an **offline test** that needs no Kong/Docker:
`luajit spec/offline/pure_algorithms_test.lua` (also `make unit-pure`).

## 9.3 Auth on Dedicated Cloud Gateways

Use an **API key** (recommended here) or a static bearer token — both avoid
in-gateway JWT signing, which keeps the handler dependency-free:

```
credentials.api_key = "{vault://env/SKYFLOW_API_KEY}"
```

Service-account JWT would require RS256 signing; on a cloud DP that means
`resty.openssl` (bundled) rather than `lua-resty-jwt`. It's a documented
follow-up; for the PoC, provision an API key with the Detect
de-identify/re-identify permission.

## 9.4 Upload & enable

> Prereq: a **Dedicated Cloud Gateways**-enabled control plane (this is a
> different/paid tier than the free Serverless gateway).

### Option A — Konnect UI
1. Control plane → **Plugins** → **Custom Plugins** → **New**.
2. Upload `schema.lua` and `handler.lua` from
   `plugin/kong/plugins/skyflow-deidentify/`.
3. Konnect validates the schema and streams the plugin to the cloud data
   planes automatically.
4. Add a **Plugin** instance (`skyflow-deidentify`) scoped to your Route/Service
   with the config from [`docs/08 §8.2`](08-operations.md#82-configuration-examples).

### Option B — Konnect API (custom plugin schema + entity)
```bash
# 1) Register the custom plugin (schema + handler) on the control plane
curl -X POST "https://{region}.api.konghq.com/v2/control-planes/{cp}/core-entities/plugin-schemas" \
  -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" \
  --data "$(jq -Rs '{ lua_schema: . }' plugin/kong/plugins/skyflow-deidentify/schema.lua)"

# (handler upload is performed via the Custom Plugins endpoint / UI; see Konnect docs)

# 2) Enable an instance on a route
curl -X POST "https://{region}.api.konghq.com/v2/control-planes/{cp}/core-entities/routes/{routeId}/plugins" \
  -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" \
  --data '{ "name": "skyflow-deidentify",
            "config": { "vault_id":"...", "cluster_id":"...",
                        "credentials": { "api_key": "{vault://env/SKYFLOW_API_KEY}" },
                        "profile":"openai",
                        "deidentify": { "entities":["NAME","EMAIL_ADDRESS"], "token_format":"VAULT_TOKEN" } } }'
```

### Option C — decK
Manage the plugin instance config declaratively (same `config` block as the
Admin API); the custom plugin code itself is uploaded once via UI/API.

## 9.5 Validate the install

```bash
# de-identify only: provider should receive tokens, client gets a normal answer
curl -i https://<your-gw-host>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Email Jane Doe at jane@acme.com"}]}'
```
Check the upstream/provider view (or a request-logging echo upstream during
testing) to confirm `Jane Doe` / `jane@acme.com` arrived as `[NAME_…]` /
`[EMAIL_ADDRESS_…]`. Enable `dry_run=true` first to observe detections without
altering traffic (see the rollout playbook in [`docs/08 §8.5`](08-operations.md#85-rollout-playbook)).

## 9.5a Free path: self-managed (hybrid) data plane on Konnect

Dedicated Cloud Gateways is a paid tier. To demo a custom plugin **on Konnect
for free**, attach a **self-managed data plane** to a hybrid control plane: you
run one Kong DP container, manage it from the Konnect UI, and the custom plugin
runs because the DP is yours. (The free **Serverless** gateway cannot run custom
plugins at all.)

A ready-to-run kit lives in [`deploy/konnect-hybrid/`](../deploy/konnect-hybrid/):
`docker-compose.yml` (DP + mock Skyflow + echo upstream), `deck/kong.yaml`
(Service/Route/plugin), and a step-by-step `README.md`. The plugin's
`require`-free `schema.lua` uploads cleanly to the control plane for hybrid
config validation — the same 2-file shape used for Dedicated Cloud Gateways.

## 9.6 Test loop recommendation

Fastest iteration is **local Docker Kong (self-managed)** with the in-repo
Skyflow mock — same two files, full `pongo`/`busted` suite, no Konnect tier
needed — then promote the validated files to the Dedicated Cloud Gateways
control plane. See [`docs/06`](06-testing.md).
