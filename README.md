# Skyflow Plugin for Kong Gateway

Put Kong in front of any LLM, MCP server, or API and guarantee that **PII, PHI,
secrets, and other regulated data are tokenized before they leave your trust
boundary** — then transparently restored for authorized callers on the way back.

The custom `skyflow-deidentify` plugin calls **Skyflow's Detect De-identify /
Re-identify APIs** to sanitize request bodies bound upstream and re-hydrate the
originals in responses. It composes with **Kong AI Gateway (`ai-proxy`)**, so
the model provider only ever sees tokens.

```text
  Client                     Kong + Skyflow                    LLM / MCP / API
  "Email Jane Doe"  ──►  de-identify (PII → tokens)  ──►  sees "[NAME_aB3xQ]"
  "…Jane Doe…"      ◄──  re-identify (tokens → PII)  ◄──  replies with tokens
                              │        ▲
                              ▼        │  Skyflow Detect  /deidentify · /reidentify
                       ┌──────────────────────────┐
                       │ Skyflow Data Privacy Vault│
                       └──────────────────────────┘
```

> **Status: working proof-of-concept.** De-identify (request) and re-identify
> (response, both `mapping_only` and vault-backed `reidentify_text`) are
> implemented and **verified end-to-end against a live Skyflow vault and real
> OpenAI, with Kong `ai-proxy` in the path**. Packaged as the two self-contained
> files Konnect requires ([`schema.lua`](plugin/kong/plugins/skyflow-deidentify/schema.lua)
> and [`handler.lua`](plugin/kong/plugins/skyflow-deidentify/handler.lua)).
> Service-account JWT auth (RS256, scoped tokens, context-aware `ctx`) is
> implemented and verified live. Streaming re-identify and file-attachment
> de-identify are documented follow-ups. See the [roadmap](#roadmap).

---

## What it does

- **De-identify on the way in** — detects and tokenizes PII/PHI/secrets in the
  request body (chat prompts, tool arguments, arbitrary JSON) before Kong
  proxies upstream. The LLM/tool receives only tokens.
- **Re-identify on the way out** — restores the original values in the response
  for authorized callers, either from a request-scoped map (`mapping_only`, no
  extra call) or vault-authoritatively via Skyflow (`reidentify_text`).
- **Works with Kong AI Gateway** — composes with `ai-proxy` (OpenAI, Anthropic,
  and other providers) via a nested-proxy pattern (see [Architecture](#architecture)).
- **Vault-backed, reversible tokenization** — values become tokens that can be
  detokenized later under Skyflow's fine-grained governance, not one-way
  placeholders. Backed by 300+ entity detectors, transformations (e.g.
  date-shifting), and multiple token formats.
- **Caller-conditional access (context-aware auth)** — with service-account JWT
  auth the gateway mints short-lived Skyflow bearers in-process and stamps them
  with a `ctx` claim of arbitrary JSON shape, layered from config
  (`context_json`/`context`), request headers, and trusted gateway-derived
  facts (`context_kong`), so vault policies can grant or mask re-identification
  per caller (`$ctx.<attr>`); `role_ids` further scope the bearer.
- **Agent tool containment** — real agent traffic (Claude Code verified live)
  works end-to-end: Anthropic-native streaming, tool calls, tool results. Tool
  inputs stay **tokenized by default** (`reidentify.tool_inputs`), so files an
  agent writes and searches it runs carry vault tokens, never raw PII — real
  values only materialize at the gateway on authorized paths.
- **Fail-closed by default** — if Skyflow is unreachable or a response can't be
  re-identified, the configured posture (`deny`) blocks rather than leaks. Also
  supports `dry_run` (log detections, don't alter traffic) and body/span limits.
- **Konnect-deployable** — ships as the two-file, `require`-free build that
  Konnect Dedicated Cloud Gateways and self-managed/hybrid data planes accept.

## Why Skyflow (vs. Kong's built-in AI Sanitizer)

Kong ships an [AI PII Sanitizer](https://developer.konghq.com/plugins/ai-sanitizer/)
that calls an external anonymizer container. This plugin follows the same proven
gateway pattern but is backed by the **Skyflow Data Privacy Vault**, adding:

- **Reversible** tokenization + **policy-governed** re-identification (per-caller
  Skyflow roles, context-aware policies, audit logging) — not just one-way masking.
- **300+ detectors**, transformations, and format-preserving / entity-only /
  unique-counter token formats.
- **Compliance posture** — data residency, isolation, and auditability provided
  by the vault, not the gateway node.

## Architecture

The plugin runs in two Kong phases: **`access`** (de-identify the request before
it's proxied) and **`response`** (re-identify the buffered response before it
reaches the client). For a plain upstream that's all you need — one route, one
plugin.

### Composing with `ai-proxy` — the nested-proxy pattern

`ai-proxy` cannot share a route with a response-phase re-identifier. It transforms
the LLM response in its `header_filter`, while re-identify must run in the
`response` phase (it calls Skyflow over a cosocket, which Kong bans in
`body_filter`). On one route the two fight over the buffered body and `ai-proxy`
returns `500 "no response body found when transforming response"` — but only when
the upstream body is gzip-encoded, which real OpenAI always is (see
[Kong #14380](https://github.com/Kong/kong/issues/14380)).

The fix is **two routes, two independent buffered cycles**:

```text
  Client
    │  "Email Jane Doe at jane@acme.com"
    ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ /ai/chat            skyflow-deidentify                        │
  │   access   : de-identify   ──►  Skyflow Detect  (PII → tokens)│
  │   response : re-identify   ◄──  Skyflow Detect  (tokens → PII)│
  └───────────────┬─────────────────────────────────▲────────────┘
                  │ tokens only (loopback)           │ tokens only
                  ▼                                  │
  ┌──────────────────────────────────────────────────────────────┐
  │ /_ai_upstream       ai-proxy  ──►  OpenAI / Anthropic / …     │
  │   (LLM sees only tokens; no skyflow plugin on this route)     │
  └──────────────────────────────────────────────────────────────┘
```

The front route does de-id + re-id and proxies to an internal route that runs
`ai-proxy` alone. The front route's upstream is `ai-proxy`'s already-transformed,
uncompressed JSON — handled exactly like a plain LLM upstream. This is verified
live and reproduced/verified offline in [`deploy/local-dbless/`](deploy/local-dbless/).

The only parties that ever see raw values are the client, Kong worker memory
(transiently), and the Skyflow vault. Full design in [`architecture`](docs/contributing/architecture.md).

## Getting started

### Prerequisites

- **Docker** + Docker Compose — for every path below.
- For the Konnect path, additionally: a **Konnect account**
  ([free sign-up](https://konghq.com/products/kong-konnect/register)),
  the [`deck`](https://docs.konghq.com/deck/) CLI, a **Skyflow vault** + a
  credential with the Detect de-identify/re-identify permissions (an API key, or
  service-account credentials JSON for JWT auth + context-aware policies), and
  (for a real LLM) an **OpenAI API key**.

### Option 1 — 60-second local demo (no accounts, no keys)

A fully self-contained harness: db-less Kong + a mock Skyflow + a gzip mock LLM.
Proves the whole de-id → `ai-proxy` → LLM → re-id round-trip offline.

```bash
docker compose -f deploy/local-dbless/docker-compose.yml up -d

curl -s localhost:8010/ai/chat -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"Reply to Jane Doe at jane@acme.com"}]}' | jq .
```

You get a normal answer with `Jane Doe` in it, while the mock LLM only ever saw
tokens:

```bash
docker logs skyflow-mock-llm-local 2>&1 | grep RECEIVED
# MOCK-LLM RECEIVED: Reply to [NAME_aB3xQ] at [EMAIL_ADDRESS_kp2]
```

The harness also includes a `/broken/chat` route that reproduces the #14380 500,
so you can see the failure the nested pattern fixes. Details:
[`deploy/local-dbless/README.md`](deploy/local-dbless/README.md).

### Option 2 — Claude Code through the gateway: real agent + real vault

Run the **actual Claude Code CLI** through Kong, with every LLM-bound byte
de-identified against a live Skyflow vault (the model provider sees only
tokens) and responses re-identified on the way back. One machine, no Konnect
account needed.

```bash
cd deploy/claude-gateway
export SKYFLOW_VAULT_ID=... SKYFLOW_CLUSTER_ID=... SKYFLOW_ACCOUNT_ID=...
export SKYFLOW_SA_JSON='{"clientID":...}'      # service-account credentials JSON
export GATEWAY_API_KEY=gw-$(openssl rand -hex 16)   # what clients will send
export ANTHROPIC_API_KEY=sk-ant-...            # provider key, gateway-held
export OPENAI_AUTH_HEADER="Bearer $OPENAI_API_KEY"  # provider key, gateway-held
./setup.sh && docker compose up -d

ANTHROPIC_BASE_URL=http://localhost:8000/claude \
ANTHROPIC_CUSTOM_HEADERS="apikey: $GATEWAY_API_KEY" \
ANTHROPIC_AUTH_TOKEN=unused \
ANTHROPIC_MODEL=claude-sonnet-4-5 CLAUDE_CODE_MAX_OUTPUT_TOKENS=8192 claude
```

**One endpoint, provider chosen by the model** — the standard AI-gateway
pattern. `/claude` routes `"model": "claude-*"` to Anthropic (native) and
anything else to OpenAI (translated), with identical Skyflow protection either
way. Switch providers with `--model gpt-4o-mini`; no URL change.

Any model either provider offers works — the upstreams deliberately set no
`model.name`, so `ai-proxy` forwards the caller's model. Verified live:
`claude-sonnet-4-5`, `claude-haiku-4-5`, `claude-opus-4-5`, `gpt-4o-mini`,
and `gpt-4o` all served from the one path.

Kong's free `ai-proxy` pins one *provider* per plugin instance, and
`ai-proxy-advanced` (multi-target routing + `model_alias`) is **enterprise-only**
— it refuses to load in free mode (`'ai-proxy-advanced' is an enterprise only
plugin`). So a bundled `pre-function` reads the request's model and rewrites the
internal loopback path. `/claude-anthropic` and `/claude-openai` remain for
pinning a provider regardless of the requested model.

### Client setup

**Claude Code** — see the quickstart above.

**Claude Desktop** (Settings → third-party inference → Gateway):

| Field | Value |
| --- | --- |
| Gateway base URL | `https://<host>/claude` |
| Gateway API key | your gateway key |
| Gateway auth scheme | **`x-api-key`** (Kong's key-auth ignores `Authorization`) |
| Model discovery | **off** — Kong exposes no `/v1/models` |
| Model list | `claude-sonnet-4-5`, `claude-haiku-4-5`, `claude-opus-4-5` |

> **Claude Desktop only accepts Anthropic model IDs.** Listing `gpt-4o-mini`
> fails config validation (`configured model "gpt-4o-mini" is not an Anthropic
> model`) — a Desktop constraint, not a gateway one. The OpenAI side of the
> toggle is reachable from Claude Code, the SDKs, and curl.

**Credential model**: the gateway holds the provider key *and* the Skyflow
service account; a client holds only a gateway key, accepted as either
`apikey` or `x-api-key` so single-credential clients (Claude Desktop) work.
Unauthenticated requests are rejected before any Skyflow call. Set
`allow_override: true` on an `ai-proxy` auth block if you'd rather callers
bring their own provider key.

Full walkthrough (verification probes, audit log, per-caller context):
[`deploy/claude-gateway/README.md`](deploy/claude-gateway/README.md).

### Option 3 — Konnect hybrid: real vault + real LLM

Run a Kong **data plane on your machine**, managed from **Konnect**, calling a
**real Skyflow vault** and a **real LLM through `ai-proxy`**. This is the
"on Konnect for free" path (custom plugins don't run on the Serverless tier;
Dedicated Cloud Gateways is the paid fully-hosted alternative).

The full step-by-step — create a hybrid control plane, generate the data-plane
cert, bring up the container, upload the plugin schema, and sync config — is in
[`deploy/konnect-hybrid/README.md`](deploy/konnect-hybrid/README.md). In short:

```bash
cd deploy/konnect-hybrid

# 1. create a hybrid control plane in Konnect, add a data-plane node to get the
#    cert + endpoints (saved to certs/ and .env), then start the DP:
docker compose up -d

# 2. upload plugin/kong/plugins/skyflow-deidentify/schema.lua to the control
#    plane once (Konnect UI → Custom Plugins), then push routes + plugin config:
export KONNECT_PAT=kpat_...
export DECK_SKYFLOW_VAULT_ID=... DECK_SKYFLOW_CLUSTER_ID=... DECK_SKYFLOW_API_KEY=...
export DECK_OPENAI_API_KEY=sk-...
deck gateway sync --konnect-token "$KONNECT_PAT" \
  --konnect-control-plane-name skyflow-hybrid \
  deck/real-vault.yaml

# 3. de-id -> ai-proxy -> real OpenAI -> re-id, all through your gateway:
curl -s localhost:8000/ai/chat -H 'content-type: application/json' \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Hi my name is Jane Doe"}]}' | jq .
```

> `deck gateway sync` makes the control plane match the file exactly and deletes
> anything not in it — each `deck/*.yaml` is a full desired state. Sync one at a
> time.

### Option 4 — streamed custom plugin (recommended for existing Konnect users)

The plugin runs on a data plane whose **image you never touch**. `handler.lua` and
`schema.lua` are uploaded to the control plane and pushed to every node over the
existing cluster connection, so installing and upgrading the plugin is an API call
(or a form in Gateway Manager) rather than a build-push-deploy cycle. This is also
the only way a custom Lua plugin can run on a Dedicated Cloud Gateway, where the
image is not yours to build.

Config lives in [`deploy/streaming/`](deploy/streaming/). Three data-plane
settings make it work, and two are non-obvious:

| Setting | Why |
| --- | --- |
| `KONG_CUSTOM_PLUGIN_STREAMING_ENABLED=on` | Defaults to **off**. Without it the control plane strips streamed plugins from the config and reports issue **P309** — and the node keeps serving its last good config, which for a privacy gateway can mean proxying with no de-identification at all. |
| `KONG_UNTRUSTED_LUA=lax` | Streamed code runs in the untrusted-Lua sandbox, which defaults to `strict` and forbids `require()`. Measured against 3.15.0.2: `strict` **fails**, `lax` **works**, `on` works but removes the sandbox entirely. `sandbox` plus `untrusted_lua_sandbox_requires` fails despite the documentation. |
| `KONG_PLUGINS=bundled` | Must **not** name `skyflow-deidentify`. Listing it makes Kong demand the code locally at boot and the node dies before the stream arrives. |

Because the handler is sandboxed, globals the sandbox withholds are nil at
runtime even though the Lua is valid — `setmetatable` cost a production outage
this way. `make globals` scans both streamed files for that class of bug.

```bash
# upload the plugin code once per control plane (Gateway Manager →
# Plugins → New plugin → Create custom plugin → Streamed custom plugin,
# or the equivalent API call):
#   POST /v2/control-planes/{cp}/core-entities/custom-plugins
#        { "name": ..., "schema": <schema.lua>, "handler": <handler.lua> }

cd deploy/streaming
export DECK_KONNECT_TOKEN=kpat_... DECK_KONNECT_ADDR=https://us.api.konghq.com
deck gateway sync kong.yaml --konnect-control-plane-name <your-cp>
```

> Streaming and the older `plugin-schemas` endpoint are **mutually exclusive**. If
> a control plane already has a registered plugin schema (Option 3), remove it
> before uploading, or the upload conflicts.

Konnect config edits reach running data planes in about ten seconds with no
restart. Plugin *code* changes need a config change alongside them to trigger the
push.

## Repository layout

```text
plugin/kong/plugins/skyflow-deidentify/
├── schema.lua      # config contract — require-free (Konnect upload constraint)
├── handler.lua     # self-contained: auth (STS delegation) + Skyflow Detect
│                   #   client + JSONPath-lite body targeting + de-id + re-id
└── *.rockspec      # self-managed / local installs only

deploy/
├── local-dbless/       # Option 1: offline harness (Kong + mock Skyflow + mock LLM)
├── claude-gateway/     # Option 2: Claude Code -> Kong -> Skyflow -> OpenAI (real vault)
├── konnect-hybrid/     # Option 3: self-managed DP on Konnect + deck configs
│   └── deck/           # real-vault.yaml, ai-gateway.yaml, kong.yaml, VERIFY-DETECT.md
└── streaming/          # Option 4: streamed custom plugin — no plugin code in the image
    ├── Dockerfile      #   data plane carrying only the three streaming settings
    └── kong.yaml       #   services, routes and plugin config (deck)

demo/                   # on-camera steps for recording the walkthrough (see demo/README.md)

spec/
├── offline/pure_algorithms_test.lua   # runs under `resty` in the Kong image (make unit-pure)
├── offline/no_undefined_globals.sh    # undefined + sandbox-forbidden globals (make globals)
└── skyflow-deidentify/                # schema + access + response specs (Pongo/busted)

docs/                    # design spec (see Documentation map below)
```

## Roadmap

The core de-identify → LLM → re-identify flow — including vault-backed
re-identify and, as of v0.3.0, service-account JWT auth (RS256) with scoped
tokens and context-aware `ctx` claims — is implemented and verified live (see
[What it does](#what-it-does)). Planned next:

| Planned | Notes |
| --- | --- |
| Streaming re-identification | Reassemble streamed responses; today `buffer` / `passthrough` |
| File-attachment de-identification | De-identify uploaded files, not just JSON request bodies |

## Documentation map

**For operators / users** — [`docs/using/`](docs/using/):

| Doc | What's inside |
| --- | --- |
| [overview.md](docs/using/overview.md) | Goals, use cases (LLM, MCP, generic), non-goals, glossary, design decisions |
| [security.md](docs/using/security.md) | Threat model, data handling, RBAC/governance, compliance, logging & redaction |
| [operations.md](docs/using/operations.md) | Config recipes (decK/Admin/KIC/Konnect), observability, latency budget, rollout |
| [deployment.md](docs/using/deployment.md) | Konnect packaging constraints, the 2-file build, upload & validate steps |

**For contributors** — [`docs/contributing/`](docs/contributing/):

| Doc | What's inside |
| --- | --- |
| [architecture.md](docs/contributing/architecture.md) | Components, phases, sequence diagrams, the `ai-proxy` nested-proxy pattern, streaming, failure modes |
| [skyflow-integration.md](docs/contributing/skyflow-integration.md) | Skyflow Detect De-identify / Re-identify / Detokenize APIs, auth, token formats, mapping model |
| [plugin-spec.md](docs/contributing/plugin-spec.md) | Full `schema.lua` config reference, handler phases, PDK usage, scoping/priority |
| [testing.md](docs/contributing/testing.md) | Unit / integration / e2e strategy, Pongo + busted, mocks, fixtures |
| [development.md](docs/contributing/development.md) | Repo layout, dependencies, local dev loop, CI |

## License & ownership

Internal Skyflow proof-of-concept. See [overview.md](docs/using/overview.md#non-goals)
for scope boundaries.
