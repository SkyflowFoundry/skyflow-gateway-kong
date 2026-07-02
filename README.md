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
> `detokenize`, service-account JWT auth, and streaming re-identify are
> documented follow-ups. See the [capability matrix](#capabilities) for details.

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
(transiently), and the Skyflow vault. Full design in [`docs/02`](docs/02-architecture.md).

## Getting started

### Prerequisites

- **Docker** + Docker Compose — for every path below.
- For the Konnect path, additionally: a **Konnect account**
  ([free sign-up](https://konghq.com/products/kong-konnect/register)),
  the [`deck`](https://docs.konghq.com/deck/) CLI, a **Skyflow vault** + API key
  with the Detect de-identify/re-identify permission, and (for a real LLM) an
  **OpenAI API key**.

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

### Option 2 — Konnect hybrid: real vault + real LLM

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

### Deploying to a paid Dedicated Cloud Gateway

Same two files, uploaded via Konnect (schema **and** handler, since Kong runs the
data plane for you). See [`docs/09`](docs/09-konnect-deployment.md).

## Repository layout

```text
plugin/kong/plugins/skyflow-deidentify/
├── schema.lua      # config contract — require-free (Konnect upload constraint)
├── handler.lua     # self-contained: auth + Skyflow Detect client + JSONPath-lite
│                   #   body targeting + de-identify + re-identify (both strategies)
└── *.rockspec      # self-managed / local installs only

deploy/
├── local-dbless/       # Option 1: offline harness (Kong + mock Skyflow + mock LLM)
└── konnect-hybrid/     # Option 2: self-managed DP on Konnect + deck configs
    └── deck/           # real-vault.yaml, ai-gateway.yaml, kong.yaml, VERIFY-DETECT.md

spec/
├── offline/pure_algorithms_test.lua   # runs under luajit — no Kong/Docker (make unit-pure)
└── skyflow-deidentify/                # schema + access + response specs (Pongo/busted)

docs/                    # design spec (see Documentation map below)
```

## Capabilities

| Capability | Status |
| --- | --- |
| De-identify request bodies (Skyflow Detect) | ✅ implemented, verified live |
| Re-identify responses — `mapping_only` (no extra call) | ✅ implemented |
| Re-identify responses — `reidentify_text` (vault-backed) | ✅ implemented, verified live |
| Compose with Kong `ai-proxy` (nested proxy) | ✅ verified live + offline |
| Profiles: `openai` / `anthropic` / `mcp` / `generic` + JSONPath-lite overrides | ✅ implemented (`openai` exercised live) |
| Fail-closed/open posture (de-id **and** re-id), `dry_run`, size/span limits | ✅ implemented |
| Auth: API key / static bearer token | ✅ implemented |
| Re-identify via vault `detokenize` | ⏳ follow-up (degrades to tokenized + warn) |
| Service-account JWT auth (RS256) | ⏳ follow-up |
| Streaming re-identify (`reassemble`) | ⏳ follow-up (`buffer`/`passthrough` today) |

## Documentation map

| Doc | What's inside |
| --- | --- |
| [`docs/01-overview.md`](docs/01-overview.md) | Goals, use cases (LLM, MCP, generic), non-goals, glossary, design decisions |
| [`docs/02-architecture.md`](docs/02-architecture.md) | Components, phases, sequence diagrams, the `ai-proxy` nested-proxy pattern, streaming, topologies, failure modes |
| [`docs/03-skyflow-integration.md`](docs/03-skyflow-integration.md) | Skyflow Detect De-identify / Re-identify / Detokenize APIs, auth, token formats, mapping model |
| [`docs/04-plugin-spec.md`](docs/04-plugin-spec.md) | Full `schema.lua` config reference, handler phases, PDK usage, scoping/priority |
| [`docs/05-implementation-plan.md`](docs/05-implementation-plan.md) | Milestones, repo layout, dependencies, tooling, CI |
| [`docs/06-testing.md`](docs/06-testing.md) | Unit / integration / e2e strategy, Pongo + busted, mocks, fixtures |
| [`docs/07-security-and-governance.md`](docs/07-security-and-governance.md) | Threat model, data handling, RBAC/governance, compliance, logging & redaction |
| [`docs/08-operations.md`](docs/08-operations.md) | Observability, caching, latency budget, rollout, decK/Konnect config examples |
| [`docs/09-konnect-deployment.md`](docs/09-konnect-deployment.md) | Konnect packaging constraints, the 2-file build, upload & validate steps |

## License & ownership

Internal Skyflow proof-of-concept. See [`docs/01-overview.md`](docs/01-overview.md#non-goals)
for scope boundaries.
