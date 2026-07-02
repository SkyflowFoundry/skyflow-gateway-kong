# 01 — Overview

## 1.1 Problem statement

Organizations are routing more traffic to LLM providers (OpenAI, Anthropic,
Bedrock, Vertex, self-hosted), to **MCP** (Model Context Protocol) servers that
expose tools/resources to agents, and to assorted third-party APIs. These
requests frequently carry **PII, PHI, secrets, and other regulated data** in
free-text prompts, tool arguments, and JSON payloads.

Once that data crosses into a third-party model or tool, the organization has
lost control of it: it may be logged, used for training, cached, or subpoenaed.
Existing controls (regex DLP, prompt filtering) are brittle and one-way.

We want a **gateway-resident control** that:

1. **De-identifies** sensitive data out of outbound requests *before* they leave
   the trust boundary, replacing it with Skyflow vault tokens or placeholders.
2. Optionally **re-identifies** (re-hydrates) the original values into the
   response stream for callers that policy authorizes — so the end-user
   experience is unchanged while the provider only ever saw tokens.

Kong Gateway is the enforcement point. Skyflow's **Detect** APIs do the
detection, tokenization, and reversible re-identification, governed by the
Skyflow Data Privacy Vault.

## 1.2 Goals

- **G1** — Intercept request bodies on configured Routes/Services and de-identify
  configured entity types via the Skyflow Detect **De-identify** API before
  proxying upstream.
- **G2** — Optionally re-identify the upstream response via the Skyflow
  **Re-identify** / **Detokenize** API before returning it to the client.
- **G3** — Be **payload-aware** for the common shapes — OpenAI / Anthropic chat
  completions, MCP JSON-RPC tool calls — while remaining **generic** (target
  arbitrary JSON fields via JSONPath, or whole-body text) so it works for
  "LLM APIs, MCP APIs, etc."
- **G4** — Fail **safely and predictably**: a configurable open/closed posture
  when Skyflow is unreachable, with no silent leakage of raw PII upstream.
- **G5** — Be production-shaped: cached auth, connection reuse, bounded latency,
  observability, and a full automated test suite.
- **G6** — Install and configure like any other Kong plugin (decK, Admin API,
  Konnect, KIC, Terraform) and compose cleanly with the bundled **AI Proxy** /
  **AI Proxy Advanced** plugins.

## 1.3 Use cases

### UC-1 — LLM chat completion (de-identify only)

A client calls `POST /v1/chat/completions` through Kong. The plugin extracts the
`messages[*].content` strings, de-identifies them, and forwards the tokenized
prompt to OpenAI (directly or via AI Proxy). The model never sees raw PII. The
response is returned as-is (it only references tokens, if any).

### UC-2 — LLM chat completion (de-identify + re-identify)

As UC-1, but `reidentify.enabled = true`. The model's answer (which may echo the
tokens it was given) is re-identified on the way back so the human sees real
values. Example: *"Email a summary to [EMAIL_ADDRESS_aB3]"* → the provider
sees the token; the user sees `jane@acme.com`.

### UC-3 — MCP tool call

An agent calls an MCP server through Kong using JSON-RPC. Tool arguments
(`params.arguments.*`) carry customer data. The plugin de-identifies the
argument values so the tool/provider operates on tokens; tool results are
optionally re-identified for the agent.

### UC-4 — Generic JSON API

Any upstream. Operator points the plugin at specific JSON fields via JSONPath
(e.g. `$.customer.notes`, `$.ticket.body`) or treats the whole body as text.

## 1.4 Non-goals

- **Not** a replacement for Kong **AI Proxy** — this plugin does *not* normalize
  provider request formats or manage provider credentials/routing. It composes
  with AI Proxy (runs before it on the request, after it on the response).
- **Not** a DLP/classification UI — entity taxonomy, policies, and audit live in
  **Skyflow**, not in the gateway.
- **Not** doing client-side cryptography or holding the vault's keys. The gateway
  holds only a Skyflow credential (API key or service-account) and call config.
- **No persistence of plaintext** at the gateway. Token↔value maps are
  request-scoped and never written to disk or shared caches (see
  [`docs/07`](07-security-and-governance.md)).
- **v1 does not** transform binary/multipart uploads or non-text modalities
  (image/audio). Skyflow Detect supports files; that is a documented v2
  extension.

## 1.5 Key design decisions

| # | Decision | Rationale | Alternatives considered |
| - | -------- | --------- | ----------------------- |
| D1 | **Lua plugin** (native PDK), name `skyflow-deidentify` | Full PDK access (body rewrite, buffered proxy, caching, timers); matches all bundled AI plugins; lowest latency; no sidecar process | Go/Python/JS PDK (extra runtime + IPC hop); external service like ai-sanitizer's anonymizer container (adds a network hop we already pay to Skyflow) |
| D2 | De-identify in **`access`**, re-identify in **`response`** (buffered) | `access` runs before upstream send and can rewrite the request body; `response` can read the full upstream body. Mirrors AI PII Sanitizer. | `body_filter` streaming rewrite (token reassembly across chunks is error-prone — offered as advanced option only) |
| D3 | Default **priority 775** + documented **dynamic ordering** before `ai-proxy`/`ai-proxy-advanced` | Must de-identify before AI Proxy (priority 770) serializes/sends the request; 775 sits just below AI PII Sanitizer (776) | Hard-coding a number only; we additionally support `ordering.before.access` |
| D4 | **Payload profiles** (`openai`, `anthropic`, `mcp`, `generic`) + JSONPath overrides | Covers the "LLM/MCP/etc." surface without bespoke code per upstream | One-size whole-body text (loses structure, risks corrupting JSON) |
| D5 | Re-hydration via Detect **`reidentify_text`** by default; **vault `detokenize`** when using `VAULT_TOKEN` per-field | `reidentify_text` restores values inside free text in one call; detokenize is the canonical per-token path for structured fields | Only one of the two (each is weak for the other payload shape) |
| D6 | **API key** credential recommended for PoC; **service-account JWT** for prod | API key avoids in-gateway RS256 signing; SA-JWT is the standard, supports scoped roles & policy context | Static bearer token (expires in 60 min — operationally poor) |
| D7 | Configurable **fail-closed** default (`on_skyflow_error = "deny"`) | A privacy control must not leak raw PII upstream when the de-identifier is down | `fail-open` available but off by default |

> These decisions are revisited where relevant in each detailed doc. Items
> flagged **(confirm)** in [`docs/03`](03-skyflow-integration.md) are tenant /
> Detect-API-version dependent and should be validated against your Skyflow
> account during implementation.

## 1.6 Glossary

| Term | Meaning |
| ---- | ------- |
| **De-identify** | Replace detected sensitive values in text with tokens/placeholders. Skyflow Detect `deidentify_text`. |
| **Re-identify** | Restore original values into previously de-identified text. Skyflow Detect `reidentify_text`. |
| **Tokenize / Detokenize** | Vault operations that swap a value for a stable token and back. `VAULT_TOKEN` format + `/detokenize`. |
| **Entity** | A class of sensitive data Skyflow can detect (e.g. `NAME`, `SSN`, `CREDIT_CARD`, `EMAIL_ADDRESS`). |
| **Token format** | `VAULT_TOKEN` (reversible, stored), `ENTITY_ONLY` (label only, one-way), `ENTITY_UNQ_COUNTER` (label + counter). |
| **Profile** | A built-in payload template telling the plugin which fields carry user text (`openai`, `anthropic`, `mcp`, `generic`). |
| **Vault** | A Skyflow Data Privacy Vault instance, addressed by `vault_id` + `cluster_id`. |
| **PDK** | Kong's Plugin Development Kit (the `kong.*` Lua API). |
| **Buffered proxy** | Kong mode where the full upstream response is buffered so a plugin can read/rewrite the body. |
| **MCP** | Model Context Protocol — JSON-RPC interface exposing tools/resources to AI agents. |

## 1.7 Compatibility target

- **Kong Gateway** 3.4 LTS+ (verified language/PDK surface), recommended 3.10+
  to sit alongside the modern AI Gateway plugin suite. Works on self-managed
  (OSS/Enterprise) and Konnect.
- **Skyflow Detect API** (text de-identify/re-identify). File/binary modalities
  are a v2 extension.
