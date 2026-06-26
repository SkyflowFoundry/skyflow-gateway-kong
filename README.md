# Skyflow Plugin for Kong Gateway

A custom [Kong Gateway](https://konghq.com/) plugin that uses **Skyflow's Detect
De-identify** and (optionally) **Re-identify** APIs to **sanitize** sensitive
data out of requests bound for LLM APIs, MCP servers, and other upstreams, and
to **re-hydrate** the original values into responses for authorized callers.

The plugin lets you put Kong in front of any AI / tool endpoint and guarantee
that PII, PHI, secrets, and other regulated data are tokenized **before** they
ever leave your trust boundary — and transparently restored on the way back
when policy allows.

```
                  de-identify (access)                  re-identify (response)
  ┌────────┐      ┌───────────────────┐     ┌────────┐  ┌────────────────────┐      ┌──────────┐
  │ Client │ ───► │  Kong + Skyflow    │ ──► │  LLM / │  │  Kong + Skyflow    │ ───► │  Client  │
  │ prompt │      │  de-identify       │     │  MCP / │  │  re-identify       │      │ response │
  └────────┘      │  (tokenize PII)    │     │  API   │  │  (detokenize)      │      └──────────┘
                  └─────────┬──────────┘     └────────┘  └─────────┬──────────┘
                            │   ▲                                  │   ▲
                            ▼   │  Detect /v1/detect/deidentify    ▼   │ Detect reidentify / Vault detokenize
                       ┌──────────────────────────────────────────────────┐
                       │                 Skyflow Data Privacy Vault         │
                       └──────────────────────────────────────────────────┘
```

> **Status:** Functional de-identify MVP (proof-of-concept), packaged for
> **Konnect Dedicated Cloud Gateways** as two self-contained files
> ([`schema.lua`](plugin/kong/plugins/skyflow-deidentify/schema.lua) +
> [`handler.lua`](plugin/kong/plugins/skyflow-deidentify/handler.lua)). The
> request **de-identify** path and `mapping_only` **re-identify** are
> implemented; `reidentify_text`/`detokenize` and service-account JWT auth are
> documented follow-ups. Core algorithms have an offline test
> (`make unit-pure`). See [`docs/09`](docs/09-konnect-deployment.md) for the
> deployment target rationale and upload steps.

---

## Why this plugin

Kong already ships an [AI PII Sanitizer](https://developer.konghq.com/plugins/ai-sanitizer/)
that calls an external anonymizer container. This plugin follows the same proven
gateway pattern but is backed by the **Skyflow Data Privacy Vault**, which adds:

- **Vault-backed, reversible tokenization** — values are swapped for tokens that
  can be detokenized later, subject to Skyflow's fine-grained governance, rather
  than only one-way placeholders.
- **Policy-governed re-identification** — re-hydration is authorized per-caller
  via Skyflow roles, context-aware policies, and audit logging.
- **300+ entity detectors, transformations** (e.g. date-shifting), and
  format-preserving / entity-only / unique-counter token formats.
- **Compliance posture** — data residency, isolation, and auditability provided
  by the vault rather than the gateway node.

## Documentation map

| Doc | What's inside |
| --- | --- |
| [`docs/01-overview.md`](docs/01-overview.md) | Goals, use cases (LLM, MCP, generic), non-goals, glossary, design decisions |
| [`docs/02-architecture.md`](docs/02-architecture.md) | Component & data-flow architecture, request/response sequence diagrams, streaming, deployment topologies, failure modes |
| [`docs/03-skyflow-integration.md`](docs/03-skyflow-integration.md) | Skyflow Detect De-identify / Re-identify / Detokenize APIs, auth, token formats, mapping model, error handling |
| [`docs/04-plugin-spec.md`](docs/04-plugin-spec.md) | Module layout, full `schema.lua` config reference, handler phases, PDK usage, scoping/priority/protocols |
| [`docs/05-implementation-plan.md`](docs/05-implementation-plan.md) | Phased milestones, repo layout, rockspec/dependencies, tooling, CI |
| [`docs/06-testing.md`](docs/06-testing.md) | Unit / integration / e2e strategy, Pongo + busted, mocks, fixtures, conformance matrix, performance & security tests |
| [`docs/07-security-and-governance.md`](docs/07-security-and-governance.md) | Threat model, data handling, RBAC/governance, compliance, logging & redaction |
| [`docs/08-operations.md`](docs/08-operations.md) | Observability, caching, latency budget, rollout, decK/Konnect config examples |
| [`docs/09-konnect-deployment.md`](docs/09-konnect-deployment.md) | **Konnect Dedicated Cloud Gateways** target: packaging constraints, 2-file build, upload & validate steps |

## Plugin (Konnect-deployable 2-file build)

```
plugin/kong/plugins/skyflow-deidentify/
├── schema.lua      # Config contract — require-free (Konnect upload constraint)
├── handler.lua     # Self-contained: auth + Skyflow Detect client + JSONPath-lite
│                   #   body targeting + de-identify + mapping_only re-identify
└── skyflow-deidentify-0.2.0-1.rockspec   # self-managed / local installs only

spec/
├── offline/pure_algorithms_test.lua      # runs under luajit — no Kong/Docker
└── skyflow-deidentify/
    ├── 01-schema_spec.lua                 # schema validation (busted)
    ├── 02-access_spec.lua                 # request de-identify (Pongo, skeleton)
    ├── 03-response_spec.lua               # response re-identify (Pongo, skeleton)
    └── helpers/mock_skyflow.lua           # in-process Skyflow Detect mock + faults
```

The logical module decomposition (auth/client/body/mapping) is described in
[`docs/02`](docs/02-architecture.md#22-module-decomposition); it is physically
inlined into `handler.lua` to satisfy the Dedicated Cloud Gateways "two
self-contained files" rule ([`docs/09`](docs/09-konnect-deployment.md)).

## Quickstart (target developer experience)

```bash
# 1. Run the test suite against a mock Skyflow Detect API (no live vault needed)
pongo run

# 2. Enable the plugin on a Route that proxies to an LLM, de-identify only
curl -i -X POST http://localhost:8001/routes/openai-route/plugins \
  --data name=skyflow-deidentify \
  --data config.vault_id=$SKYFLOW_VAULT_ID \
  --data config.cluster_id=$SKYFLOW_CLUSTER_ID \
  --data config.credentials.api_key=$SKYFLOW_API_KEY \
  --data 'config.profile=openai' \
  --data 'config.deidentify.entities=NAME,SSN,CREDIT_CARD,EMAIL_ADDRESS,PHONE_NUMBER'

# 3. (optional) Turn on re-identification of responses
curl -i -X PATCH http://localhost:8001/plugins/<id> \
  --data config.reidentify.enabled=true
```

See [`docs/08-operations.md`](docs/08-operations.md) for decK, Konnect, and
Kubernetes (KIC) configuration examples.

## License & ownership

Internal Skyflow proof-of-concept. See [`docs/01-overview.md`](docs/01-overview.md#non-goals)
for scope boundaries.
