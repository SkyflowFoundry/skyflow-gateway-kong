# Partner plugin doc submission — `skyflow-ai-data-control`

> Filled-in submission for Kong's partner plugin doc template
> (see [`partner-submission.md`](partner-submission.md) for the blank skeleton and
> the [`prisma-airs-intercept`](https://developer.konghq.com/plugins/prisma-airs-intercept/)
> reference sample this mirrors).

## Samples

Format model: [https://developer.konghq.com/plugins/prisma-airs-intercept/](https://developer.konghq.com/plugins/prisma-airs-intercept/)

## Required collateral

- **Logo icon (64×64 PNG/SVG)** — _TODO: Skyflow brand asset to be provided._ Not in repo.
- **Plugin schema (JSON)** — [`skyflow-ai-data-control.schema.json`](skyflow-ai-data-control.schema.json)
  (generated from the plugin's `schema.lua`).
- **Luarock** — `skyflow-ai-data-control` (`skyflow-ai-data-control-0.2.0-1`).
  Source: `git+https://github.com/SkyflowFoundry/skyflow-kong-poc.git`, tag `v0.2.0`.
  For Konnect, the plugin is uploaded as two self-contained files
  (`schema.lua` + `handler.lua`) rather than a rock.

## Doc template

### Introduction

Use the **Skyflow De-identify** plugin (`skyflow-ai-data-control`) to put Kong in front of any
LLM, MCP server, or API and guarantee that **PII, PHI, secrets, and other regulated data
are tokenized before they leave your trust boundary** — then transparently restored for
authorized callers on the way back.

Applications increasingly send prompts, tool arguments, and JSON payloads to LLM
providers, MCP servers, and third-party APIs — often carrying regulated data. Once that
data reaches a third party you've lost control of it: it can be logged, trained on,
cached, or subpoenaed. This plugin makes Kong the enforcement point and the
**Skyflow Data Privacy Vault** the system of record: Skyflow's **Detect** APIs do the
detection, reversible tokenization, and policy-governed re-identification, so the model
provider only ever sees tokens.

Benefits of de-identifying traffic with the Skyflow De-identify plugin:

- **Reversible, policy-governed tokenization** — values become Skyflow vault tokens that
  can be re-identified per-caller under Skyflow roles, context-aware policies, and audit
  logging. Not just one-way masking.
- **300+ entity detectors and transformations** — names, emails, SSNs, credit cards,
  healthcare identifiers, and more, plus transformations such as date-shifting and
  multiple token formats (`VAULT_TOKEN`, `ENTITY_ONLY`, `ENTITY_UNQ_COUNTER`).
- **Composes with Kong AI Gateway** — sits alongside `ai-proxy` via a nested-proxy pattern
  so the model provider (OpenAI, Anthropic, and others) receives only tokens.
- **Fail-closed by default** — if Skyflow is unreachable or a response can't be
  re-identified, the configured posture (`deny`) blocks rather than leaks. A `dry_run`
  mode logs detections without altering traffic.
- **Deployable on Konnect and self-managed** — ships as two self-contained, `require`-free
  files that Konnect Dedicated Cloud Gateways and hybrid data planes accept, and as a
  LuaRock for self-managed installs.

### How it works

When you enable this plugin on a route, it acts in two Kong request-lifecycle phases:

- **`access`** — runs before the request is proxied upstream. The plugin reads the request
  body, extracts the target text spans (selected by a **profile** — `openai`, `anthropic`,
  `mcp`, or `generic` — or by explicit JSONPath selectors), calls Skyflow **De-identify**
  (`POST /v1/detect/deidentify/string`), and rewrites the outbound body so the upstream
  receives only tokens (e.g. `[NAME_aB3xQ]`). A request-scoped token→value map is stashed
  for the response phase.
- **`response`** — runs after the full upstream response is buffered but before any byte
  reaches the client. When `reidentify.enabled = true`, the plugin restores the original
  values (via `mapping_only`, the request-scoped map, or `reidentify_text`, a
  vault-authoritative call to `POST /v1/detect/reidentify/string`) and rewrites the
  response body. The end-user sees real values; the provider never did.

```text
            ┌───────────────────── Kong worker (OpenResty) ─────────────────────┐
 client ───▶│  ACCESS* │ ──────────▶ upstream ──────────▶ │ RESPONSE* │ │ log │ │───▶ client
            └──────┼──────────────────────────────────────────┼──────────┼──────┘
                   │ de-identify                               │ re-id    │ metrics
                   ▼                                           ▼          ▼
            Skyflow Detect                              Skyflow Detect  (no PII)
            /deidentify                                 /reidentify
            * skyflow-ai-data-control phases
```

**Entities it interacts with.** The plugin attaches to Kong Routes and Services and talks
to the Skyflow Detect API over HTTPS using a bearer token minted from the configured
credential. It emits metrics and structured logs of detected-entity counts by type — never
the values themselves.

**Deterministic tokens.** With `VAULT_TOKEN`, the same input value always maps to the same
token, so multi-message and multi-turn conversations stay coherent even though the provider
only ever saw opaque tokens.

**Composing with Kong AI Gateway (`ai-proxy`).** The plugin does **not** share a route with
`ai-proxy`. `ai-proxy` transforms the LLM response in its `header_filter`, while
re-identify must run in the `response` phase (it calls Skyflow over a cosocket, which Kong
bans in `body_filter`); on one route the two contend for the buffered body and `ai-proxy`
returns `500 "no response body found when transforming response"` whenever the upstream
body is gzip-encoded — which real OpenAI always is
([Kong #14380](https://github.com/Kong/kong/issues/14380)). The fix is a **nested-proxy
topology**: two routes, two independent buffered cycles.

```text
  Client "Email Jane Doe at jane@acme.com"
    │
    ▼
  /ai/chat            skyflow-ai-data-control only
    access  : de-identify (PII → tokens) ──▶ Skyflow Detect
    response: re-identify (tokens → PII) ◀── Skyflow Detect
    │  tokens only (loopback to 127.0.0.1:8000/_ai_upstream)   ▲ tokens only
    ▼                                                          │
  /_ai_upstream       ai-proxy only ──▶ OpenAI / Anthropic / … (sees only tokens)
```

**Real agent traffic.** Beyond simple JSON bodies, the plugin handles coding-agent /
MCP traffic: it reads large bodies that nginx spools to disk, re-identifies values inside
`tool_calls[].function.arguments` (not just message content), and buffers streaming
(`stream: true`) responses — re-identifying the full completion, then re-emitting it as
SSE — so a token split across chunks is never leaked.

### Installation details

Luarock name: `skyflow-ai-data-control` (`skyflow-ai-data-control-0.2.0-1`).

**Self-managed Kong (OSS / Enterprise):**

```bash
luarocks make        # builds the skyflow-ai-data-control rock
# then enable it on the node:
export KONG_PLUGINS=bundled,skyflow-ai-data-control
```

Dependencies: `lua >= 5.1` and `lua-resty-http >= 0.17` (`resty.http` and `cjson` are
provided by the Kong/OpenResty runtime).

**Konnect (Dedicated Cloud Gateways / hybrid data planes):** do not use the rock. Upload
the two self-contained files — `schema.lua` and `handler.lua` — to the control plane as a
custom plugin (Konnect → Plugins → Custom Plugins). The build is `require`-free and uses
only Kong-bundled runtime libraries, which is what Konnect's custom-plugin upload requires.

### Example configuration

**Prerequisites.** Before enabling the plugin you need:

- A **Skyflow account** and a **Data Privacy Vault** — you'll need its `vault_id` and
  `cluster_id`.
- A **Skyflow credential** with the "De-identify and reidentify sensitive data in text and
  files" permission — an `api_key` or static `token`. Store it as a Kong secret/vault
  reference; the credential fields are referenceable and stored encrypted.

**De-identify only (the model never sees raw PII).** In the following example, the plugin
tokenizes the chat prompt (`messages[*].content`, via the `openai` profile) before Kong
proxies the request. Re-identification is off, so the tokens are what the caller sees too —
useful for a strict egress posture.

```yaml
plugins:
  - name: skyflow-ai-data-control
    config:
      vault_id: "{vault_id}"
      cluster_id: "{cluster_id}"
      env: PROD
      credentials:
        api_key: "{vault://env/SKYFLOW_API_KEY}"
      profile: openai
      deidentify:
        entities: [NAME, EMAIL_ADDRESS, PHONE_NUMBER, SSN, CREDIT_CARD]
        token_format: VAULT_TOKEN
```

**De-identify + re-identify (provider sees tokens, caller sees real values).** Same as
above, but the plugin restores the original values in the response. `reidentify.strategy`
= `reidentify_text` resolves tokens vault-authoritatively (requires `VAULT_TOKEN`), and
`entity_treatment` masks / redacts selected types on the way back.

```yaml
plugins:
  - name: skyflow-ai-data-control
    config:
      vault_id: "{vault_id}"
      cluster_id: "{cluster_id}"
      credentials:
        api_key: "{vault://env/SKYFLOW_API_KEY}"
      profile: openai
      deidentify:
        entities: [NAME, EMAIL_ADDRESS, PHONE_NUMBER, SSN, CREDIT_CARD]
        token_format: VAULT_TOKEN
      reidentify:
        enabled: true
        strategy: reidentify_text
        default_treatment: plain_text
        entity_treatment:
          CREDIT_CARD: masked
          SSN: redacted
      on_skyflow_error: deny
```

What the config does:

- `vault_id` / `cluster_id` / `env` — which Skyflow vault and environment to call.
- `credentials.sts` — the delegating service-account ID plus the expected IdP issuer and audience. Not a secret: the gateway holds no Skyflow credential, and vault access requires a live caller IdP token exchanged per request (RFC 8693).
- `profile: openai` — targets OpenAI Chat Completions fields; use `anthropic`, `mcp`, or
  `generic` (with `request_json_paths`) for other payload shapes.
- `deidentify.entities` — the entity types to detect (empty = Skyflow's default set).
- `deidentify.token_format: VAULT_TOKEN` — reversible, deterministic tokens.
- `reidentify.enabled: true` + `strategy: reidentify_text` — restore originals in the
  response, resolved through the vault.
- `entity_treatment` — mask `CREDIT_CARD`, redact `SSN` even when re-identifying.
- `on_skyflow_error: deny` — fail closed if Skyflow is unreachable.

> **Configuration constraints** (enforced by the schema): `reidentify.strategy =
> reidentify_text` requires `deidentify.token_format = VAULT_TOKEN`; `mapping_only`
> requires a token format other than `ENTITY_ONLY`; `deadline_ms` must be `>= timeout_ms`;
> the `generic` profile requires `request_json_paths` or `content_type: text`. See
> [`skyflow-ai-data-control.schema.json`](skyflow-ai-data-control.schema.json) for the full field
> reference.
