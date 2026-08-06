# Skyflow AI Data Control for Kong Gateway

**Runtime data control for agents and models — added to a Kong gateway you already
run, without touching its image.**

Set three environment variables, upload two Lua files from Gateway Manager, attach
the plugin to your AI route. Sensitive values are then replaced with vault tokens
before a prompt leaves your network, and restored on the way back, so the model
provider only ever sees tokens.

Both reference gateways run stock `kong/kong-gateway:3.15.0.2` from Docker Hub. The
plugin arrives over the cluster connection at runtime — it is never in the image.
See [`deploy/streaming/data-plane-env.md`](deploy/streaming/data-plane-env.md).

```mermaid
flowchart LR
    C["<b>Client</b><br/>Email Jane Doe"]
    K["<b>Kong + Skyflow</b><br/>access: de-identify<br/>response: re-identify"]
    L["<b>LLM / MCP / API</b><br/>sees only<br/>[NAME_aB3xQ]"]
    V[("<b>Skyflow</b><br/>Data Privacy Vault")]

    C -- "PII" --> K
    K -- "tokens" --> L
    L -- "tokens" --> K
    K -- "PII restored" --> C
    K <-. "Detect<br/>/deidentify · /reidentify" .-> V

    classDef clear fill:#f7ebe3,stroke:#9c4221,color:#16191f
    classDef safe  fill:#e4efed,stroke:#1b5e5a,color:#16191f
    classDef vault fill:#ede9f6,stroke:#4c3a8c,color:#16191f
    class C clear
    class L safe
    class K safe
    class V vault
```

> **Status: working proof-of-concept.** Verified end-to-end against a live Skyflow
> vault with real Anthropic and OpenAI traffic and `ai-proxy` in the path: both
> legs, Anthropic-native streaming, tool calls, binary attachments, and all three
> auth methods. See the [roadmap](#roadmap).

---

## Contents

- [Quickstart](#quickstart) — offline in one command, or on your own gateway in four steps
- [What it does](#what-it-does)
- [Authentication](#authentication) — `sts` / `jwt_credential` / `bearer_token`, and how `ctx` is derived
- [Why Skyflow (vs. Kong's built-in AI Sanitizer)](#why-skyflow-vs-kongs-built-in-ai-sanitizer)
- [Architecture](#architecture) — the nested-proxy pattern and why it is required
- [Getting started](#getting-started) — prerequisites, offline harness, installing on Konnect
- [Repository layout](#repository-layout)
- [Roadmap](#roadmap)
- [Documentation map](#documentation-map)

## Quickstart

**Check the wiring offline, no accounts and no keys** — db-less Kong, a mock
Skyflow and a mock LLM. Both assertions read external evidence rather than the
plugin's own claims: the tokens come from the mock LLM's *own* access log, and the
restored values from the response body the client received.

```bash
make e2e
# upstream saw: MOCK-LLM RECEIVED: Reply to [NAME_aB3xQ] at [EMAIL_ADDRESS_kp2]
# ok: tokenized on egress, restored to the client
```

What this does and does not establish is worth being precise about. It proves the
plugin loads in a real gateway, that both phases run in the right order, and that
the rewritten body actually reaches the upstream — the class of fault that unit
tests structurally cannot see, since they call the pure functions directly and
never traverse a request. It caught two real regressions during development that a
full unit suite passed straight through.

It does **not** prove detection works. The mock replaces known fixture strings
from a lookup table; it runs no detector and ignores the entity list, so a request
that reaches it with the wrong entities, the wrong vault destination, or a
malformed payload still comes back looking correct. For that, point it at a real
vault (`docs/using/operations.md`).

**Install it on your own Konnect gateway** — four steps, three of them in the UI:

1. **Set three data-plane variables and restart.** The only step outside Gateway
   Manager, and the only one needing a restart. Apply them wherever you manage
   the container's environment — Helm values, an ECS task definition, `docker run -e`.

   ```bash
   KONG_CUSTOM_PLUGIN_STREAMING_ENABLED=on   # defaults OFF; without it you get a P309
   KONG_UNTRUSTED_LUA=lax                    # `strict` forbids require(); the plugin will not load
   KONG_PLUGINS=bundled                      # must NOT name skyflow-ai-data-control
   KONG_VAULTS=bundled                       # needed for any {vault://env/...} config reference
   ```

2. **Build the upload payload.** Konnect caps handler code at 102,400 bytes, so
   this strips comments and verifies the stripped result still passes the suite.

   ```bash
   make bundle
   # handler: 119788 -> 58489 bytes (limit 102400)
   # writes custom-plugin.json  (for the API)
   # writes upload/handler.lua + upload/schema.lua  (for the UI)
   ```

3. **Upload it.** Gateway Manager → Plugins → *New plugin* → *Create custom
   plugin* → **Streamed custom plugin** (not Installed — that is the one that
   needs an image rebuild). Or `POST` the `custom-plugin.json` from step 2 to
   `/v2/control-planes/{cp}/core-entities/custom-plugins`.

   Two things make this fail, and neither error says so plainly:

   - **Name it `skyflow-ai-data-control`, exactly.** Konnect compares it against
     the name declared inside `schema.lua`, so a plausible variant is rejected.
   - **Upload the files from `upload/`, not from `plugin/kong/plugins/`.** The
     source handler is over Konnect's 102,400-byte cap; `upload/handler.lua` is
     the stripped copy that fits. Put `schema.lua` in the *schema* slot and
     `handler.lua` in the *handler* slot — transposing them reports
     `schema - require not permitted in sandbox: resty.http`, which looks like a
     data-plane sandbox problem and is not one.

4. **Attach it** to the service carrying model traffic — scoped, not global — and
   fill in `skyflow.vault_configuration`: **vault id**, **vault url** (paste it
   whole, e.g. `https://ebfc9bee4242.vault.skyflowapis.com`) and **account id**.
   All three appear on your vault's own page in the Skyflow console, under those
   same names.

   Then pick a credential. `skyflow.credentials.method` selects one and there is
   no fallback between them:

   | `method` | You supply | Use when |
   | --- | --- | --- |
   | `bearer_token` | `bearer_token.api_key` | Simplest. A Skyflow bearer, used as-is — no IdP needed. |
   | `jwt_credential` | `jwt_credential.service_account_json` | The service-account JSON. The gateway signs and exchanges it itself; still no IdP. |
   | `sts` *(default)* | `sts.service_account_id` + `expected_issuer` + `expected_audience` | You have an enterprise IdP and want the gateway to hold **no** Skyflow credential at all — it exchanges each caller's own token per request (RFC 8693), so Skyflow logs the human, not the gateway. |

   Everything else has a safe default. Nothing selects the API format: OpenAI,
   Anthropic and MCP payloads are detected per request from the body shape, so
   one config serves all three.

Then confirm it is really in the path — an unauthenticated request must be
refused, because there is no caller identity to exchange:

```bash
curl -s -X POST https://<your-gateway>/ai/v1/messages \
  -H 'content-type: application/json' \
  -d '{"model":"claude-sonnet-4-5","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}'
# → request blocked: no caller identity token in 'authorization'
```

> The check that actually proves the product is the *egress* payload, not the
> response you get back — the client sees restored cleartext by design, so a
> working gateway and a broken one look identical from there. See
> [Getting started](#getting-started).

---

## What it does

- **De-identifies on the way in** — PII/PHI/secrets in the request body become
  **deterministic vault tokens**, so the model can still compare, group and reason
  over values it is never allowed to read.
- **Re-identifies on the way out**, governed by Skyflow vault policy rather than by
  the gateway — so *who is asking* decides what comes back in the clear.
- **Contains agent tools** — tool inputs stay tokenized by default, so files an
  agent writes and commands it runs carry tokens, not raw PII.
- **Fails closed** — if Skyflow is unreachable or a body cannot be parsed, the
  request is denied rather than forwarded in the clear.

Composes with **Kong AI Gateway (`ai-proxy`)** via a nested-proxy pattern; see
[Architecture](#architecture) for why two routes are required.

## Authentication

`credentials.method` selects how the plugin obtains a Skyflow bearer. The three
options are not interchangeable — they differ in what the vault learns about who
is asking, and therefore in what your vault policies can enforce.

| Method | Gateway holds a Skyflow credential? | Identity the vault sees | `ctx` |
| --- | --- | --- | --- |
| **`sts`** (default) | **No** | The caller's own IdP-signed token, via RFC 8693 exchange | Present, **not configurable** |
| **`jwt_credential`** | Yes — a private key | Asserted by the gateway | Present **and configurable** |
| **`bearer_token`** | Yes — a long-lived key | None; every request looks identical | **None** |

`sts` is the default because it is the only method where compromising the data
plane yields nothing reusable, and the identity in Skyflow's audit trail is a
person's rather than a machine's.

**`ctx` is never configured — it is derived.** There is no ctx knob under any
method, and the schema rejects one:

- Under **`jwt_credential`**, the plugin stamps `ctx` itself from facts it derives
  at request time: route, service, consumer, client IP. Those are the only context
  the caller cannot forge. `service_account_json` is the single field on this
  record.
- Under **`sts`**, `ctx` is the IdP's signed claims. Skyflow ignores context
  supplied by the caller of an exchange, so there is nothing for the gateway to
  add. Put tenant, role and purpose in the IdP token — Entra app roles and
  claims-mapping policies — where they are IdP-signed.
- Under **`bearer_token`** there is no assertion to carry claims at all.

An earlier draft let operators map request **headers** into ctx claims. That
inverted the trust model: it fed caller-controlled values into the claim set the
vault uses for policy decisions, so anyone able to reach the gateway could assert
their own tenant or purpose. Removed rather than documented.

Two limits worth stating plainly. Under `jwt_credential` there is no caller
identity, so `ctx` describes the **gateway**, never the person — per-user vault
policy requires `sts`. And the failure this design prevents is the quiet one: a
policy keyed on `$ctx.purpose` that reads as configured and never fires because
nothing populates `purpose`.

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

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant F as Front route /ai/chat<br/>(skyflow-ai-data-control)
    participant U as Internal route<br/>(ai-proxy only)
    participant P as OpenAI / Anthropic
    participant S as Skyflow Detect

    C->>F: Email Jane Doe at jane@acme.com
    Note over F: access phase
    F->>S: de-identify
    S-->>F: [NAME_aB3xQ] · [EMAIL_ADDRESS_kp2]
    F->>U: tokens only, over loopback
    U->>P: tokens only
    P-->>U: reply, still tokenized
    U-->>F: transformed, uncompressed JSON
    Note over F: response phase
    F->>S: re-identify
    S-->>F: original values
    F-->>C: reply with Jane Doe restored
```

Two routes means two independent buffered cycles. The front route does de-id and
re-id; its upstream is an internal route running `ai-proxy` alone, so the front
route only ever sees `ai-proxy`'s already-transformed, uncompressed JSON — which
it can handle exactly like a plain LLM upstream. Verified live, and reproduced
offline in [`test/offline-harness/`](test/offline-harness/).

The only parties that ever see raw values are the client, Kong worker memory
(transiently), and the Skyflow vault. Full design in [`architecture`](docs/contributing/architecture.md).

## Getting started

### Prerequisites

- **Docker** + Docker Compose — for the offline harness.
- To install on your own gateway, additionally: a **Konnect account**
  ([free sign-up](https://konghq.com/products/kong-konnect/register)),
  the [`deck`](https://docs.konghq.com/deck/) CLI, a **Skyflow vault**, and a
  **service account** configured for RFC 8693 token exchange with the Detect
  de-identify/re-identify permissions. On the default `sts` method the gateway
  holds no Skyflow credential of its own — it exchanges the caller's own identity
  token for a short-lived bearer, so there is no API key to configure. For a real
  LLM you also need an **OpenAI** or **Anthropic** API key for `ai-proxy`.

### Try it offline first (no accounts, no keys)

A fully self-contained harness: db-less Kong + a mock Skyflow + a gzip mock LLM.
Proves the whole de-id → `ai-proxy` → LLM → re-id round-trip offline.

```bash
make e2e     # brings the stack up, asserts both directions, tears it down
```

Or drive it by hand. The default auth method is `sts`, so every request needs a caller
identity token; the harness leaves `expected_issuer`/`expected_audience` unset so
an unsigned fixture JWT is enough — still no accounts and no keys:

```bash
docker compose -f test/offline-harness/docker-compose.yml up -d --wait

JWT=eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJkZW1vLXVzZXIiLCJlbWFpbCI6ImRlbW9AZXhhbXBsZS5jb20iLCJuYW1lIjoiRGVtbyBVc2VyIn0.sig

curl -s localhost:8010/ai/chat -H 'content-type: application/json' \
  -H "authorization: Bearer $JWT" \
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
[`test/offline-harness/README.md`](test/offline-harness/README.md).

### Install it — streamed custom plugin

This is the only supported integration path. The plugin runs on a data plane
whose **image you never touch**. `handler.lua` and
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
| `KONG_PLUGINS=bundled` | Must **not** name `skyflow-ai-data-control`. Listing it makes Kong demand the code locally at boot and the node dies before the stream arrives. |

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
> a control plane already has a registered plugin schema from an older build,
> remove it
> before uploading, or the upload conflicts.

Konnect config edits reach running data planes in about ten seconds with no
restart. Plugin *code* changes need a config change alongside them to trigger the
push.

## Repository layout

```text
plugin/kong/plugins/skyflow-ai-data-control/
├── schema.lua      # config contract — require-free (Konnect upload constraint)
├── handler.lua     # self-contained: auth (STS delegation) + Skyflow Detect
│                   #   client + JSONPath-lite body targeting + de-id + re-id
└── *.rockspec      # self-managed / local installs only

deploy/streaming/        # THE deployment path — there is deliberately only one
├── Dockerfile           #   data plane carrying only the three streaming settings
└── kong.yaml            #   services, routes and plugin config (deck)

test/offline-harness/    # NOT a deployment option: a self-contained test fixture
├── docker-compose.yml   #   db-less Kong + mock Skyflow + gzip mock LLM
├── kong.yaml
├── mock-skyflow/        #   canned reversible tokenization + a mock STS endpoint
└── mock-llm/            #   logs what the upstream actually received

scripts/
└── bundle-streamed-plugin.sh   # strips comments to fit Konnect's 102,400-byte cap

spec/
├── offline/pure_algorithms_test.lua   # runs under `resty` in the Kong image (make unit-pure)
├── offline/no_undefined_globals.sh    # undefined + sandbox-forbidden globals (make globals)
├── offline/auth_methods_test.sh       # auth methods + the ctx asymmetry (make auth-methods)
└── skyflow-ai-data-control/                # schema + access + response specs (Pongo/busted)

demo/                    # on-camera steps for recording the walkthrough
docs/                    # design spec (see Documentation map below)
```

## Roadmap

The core de-identify → LLM → re-identify flow is implemented and verified live
(see [What it does](#what-it-does)), including vault-backed re-identification,
all three credential methods, and per-request detection of the wire format.
Planned next:

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
