# Overview

Applications increasingly send prompts, tool arguments, and JSON payloads to LLM
providers, MCP servers, and third-party APIs — often carrying **PII, PHI,
secrets, and other regulated data**. Once that data reaches a third party you've
lost control of it: it can be logged, trained on, cached, or subpoenaed.

`skyflow-deidentify` is a Kong Gateway plugin that puts a privacy control at the
gateway:

- **De-identifies** sensitive values out of outbound requests *before* they leave
  your trust boundary, replacing them with Skyflow vault tokens.
- Optionally **re-identifies** (restores) the original values in the response for
  authorized callers — so the end-user experience is unchanged while the provider
  only ever saw tokens.

Kong is the enforcement point; Skyflow's **Detect** APIs do the detection,
tokenization, and reversible re-identification, governed by the Skyflow Data
Privacy Vault. For the request/response flow and how it composes with `ai-proxy`,
see [architecture](../contributing/architecture.md).

## Use cases

- **LLM chat, de-identify only** — a client calls `POST /v1/chat/completions`
  through Kong; the plugin tokenizes `messages[*].content` before it reaches the
  provider. The model never sees raw PII.
- **LLM chat, de-identify + re-identify** — as above, but the model's answer
  (which may echo the tokens it was given) is restored on the way back, so the
  human sees real values and the provider never did.
- **MCP tool calls** — tool arguments (`params.arguments.*`) are tokenized so the
  tool/provider operates on tokens; results are optionally re-identified.
- **Generic JSON APIs** — point the plugin at specific JSON fields (via JSONPath,
  e.g. `$.customer.notes`) or treat the whole body as text.

## Non-goals

- **Not** a replacement for Kong **AI Proxy** — it does not normalize provider
  request formats or manage provider credentials/routing. It composes with AI
  Proxy via a [nested-proxy topology](../contributing/architecture.md#28-deployment-topologies).
- **Not** a DLP/classification UI — entity taxonomy, policies, and audit live in
  **Skyflow**, not the gateway.
- **Not** client-side cryptography or key custody. The gateway holds only a
  Skyflow credential and call config.
- **No plaintext at rest** — token↔value maps are request-scoped and never
  written to disk or shared caches (see [security](security.md)).
- **No binary/multipart or non-text modalities** (image/audio) yet — a documented
  future extension.

## Glossary

| Term | Meaning |
| --- | --- |
| **De-identify** | Replace detected sensitive values in text with tokens. |
| **Re-identify** | Restore original values into previously de-identified text. |
| **Tokenize / Detokenize** | Vault operations that swap a value for a stable token and back (`VAULT_TOKEN` format). |
| **Entity** | A class of sensitive data Skyflow detects (`NAME`, `SSN`, `CREDIT_CARD`, `EMAIL_ADDRESS`, …). |
| **Token format** | `VAULT_TOKEN` (reversible, stored) · `ENTITY_ONLY` (label only, one-way) · `ENTITY_UNQ_COUNTER` (label + counter). |
| **Profile** | Built-in payload template for which fields carry user text (`openai`, `anthropic`, `mcp`, `generic`). |
| **Vault** | A Skyflow Data Privacy Vault, addressed by `vault_id` + `cluster_id`. |
| **MCP** | Model Context Protocol — JSON-RPC interface exposing tools/resources to AI agents. |

## Compatibility

- **Kong Gateway** 3.4 LTS+ (3.10+ recommended to sit alongside the AI Gateway
  plugin suite). Works self-managed (OSS/Enterprise) and on Konnect.
- **Skyflow Detect API** for text de-identify/re-identify. File/binary modalities
  are a future extension.
