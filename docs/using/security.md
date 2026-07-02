# Security & Governance

The plugin *is* a security control, so its own security posture matters as much
as its function. This document covers the threat model, data handling, secrets,
governance/RBAC, compliance, and the privacy invariants enforced by tests
([`testing §6.5`](../contributing/testing.md#65-security--privacy-tests-must-pass-invariants)).

## 7.1 Security objectives

- **SO1 — No raw sensitive data reaches the upstream** (LLM/MCP/API) when
  de-identify is active. This is the core promise; tested as *no-leak-upstream*.
- **SO2 — Re-identification is authorized and governed** by Skyflow (roles,
  policies, audit) — the gateway cannot unilaterally reveal more than policy
  permits.
- **SO3 — No sensitive data persists at the gateway** (no disk, no shared cache,
  no logs).
- **SO4 — Credentials are protected** at rest and in transit and never exposed
  via the Admin API.
- **SO5 — Fail closed**: faults degrade toward *less* exposure, never more.

## 7.2 Threat model (STRIDE-ish)

| Threat | Vector | Mitigation |
| ------ | ------ | ---------- |
| **Data exfiltration to provider** | PII forwarded before tokenization | De-identify in `access` before upstream send; fail-closed default; *no-leak-upstream* test; auth failures always deny. |
| **Leak via logs/metrics** | Values printed in debug/error logs | Logs carry **counts/types only**; *no-PII-in-logs* test; sampling doesn't change redaction; pcall error paths log messages, not bodies. |
| **Leak via cache/state** | Plaintext written to `kong.cache`/disk | Only the bearer token is cached; mapping is request-scoped (`kong.ctx.plugin`); *no-PII-at-rest* test. |
| **Credential theft** | Reading plugin config / DB / Admin API | Credentials `encrypted` + `referenceable` (`{vault://…}`); never returned by `GET /plugins`; keyring/Vault-backed in prod. |
| **Unauthorized re-identification** | Caller restores data they shouldn't | Skyflow roles + policy `ctx` derived from the Kong Consumer; `entity_treatment` masks/redacts even on the return path; `mapping_only` avoids any vault detokenize. |
| **Token forgery / replay** | Crafted tokens in a response to detokenize arbitrary data | `mapping_only` restores only tokens minted **this** request; `detokenize`/`reidentify` are governed by vault policy regardless of token origin. |
| **MITM to Skyflow** | Network interception | TLS to `*.vault.skyflowapis.com`; cert verification on (no `ssl_verify=false` in prod); optional pinning. |
| **DoS / amplification** | Huge bodies, many spans | `max_body_size`, `max_spans`, `max_concurrency`, `deadline_ms`; oversized ⇒ posture. |
| **Tampering with ordering** | Raw PII reaches upstream before tokenization | De-identify runs in `access` before the request is proxied; with `ai-proxy` the nested-proxy topology keeps de-identify on the front route so the internal `ai-proxy` route only ever receives tokens. |
| **Replay of bearer token** | Stolen cached token reused | Short TTL (~60 min) + skew refresh; SA-JWT scoped to roles; rotate on incident. |
| **Supply chain** | Compromised rock dependency | Minimal deps (`resty.http`, optional `resty.jwt`); pinned versions; CI dependency review; prefer bundled `resty.openssl`. |

## 7.3 Data handling & residency

- **In memory only.** Request/response bodies and the token↔value map exist
  solely in worker memory for the request's lifetime; GC'd at request end.
- **PII egress is to the vault only.** The single external destination that ever
  sees raw values is Skyflow over TLS. The upstream sees tokens.
- **Residency** is governed by the Skyflow vault region (`cluster_id`/env), not
  the gateway. For data-residency requirements, point at the in-region cluster
  and pin `skyflow_base_url_override` to the regional/private endpoint.
- **No analytics on values.** Metrics are aggregate counts by entity type.

## 7.4 Secrets management

- Credentials are schema-typed `encrypted` + `referenceable`:
  - **PoC:** `credentials.api_key` via env/Kong vault reference.
  - **Prod:** `credentials.service_account_json` via Kong **Secrets
    Management** (`{vault://env/...}`, HashiCorp Vault, AWS SM, GCP SM).
- The RSA private key (SA-JWT) is used only to sign the short-lived assertion;
  it is read from the referenced secret, never logged, never echoed.
- Rotation: API keys rotated out-of-band; SA keys rotated in Skyflow Studio and
  swapped via the secret reference with no plugin code change.

## 7.5 Governance & RBAC (delegated to Skyflow)

The gateway delegates *authorization of data exposure* to Skyflow so that policy
is centralized and audited:

- **Roles:** the gateway's service account is granted exactly the Detect
  permissions it needs (de-identify/re-identify; detokenize only if used). Least
  privilege — a de-identify-only deployment need not hold detokenize rights.
- **Policy context:** scoped tokens carry `ctx` (e.g. consumer id, department)
  so Skyflow policies can allow/deny re-identification per caller, enabling
  end-to-end, attribute-based governance without gateway-side authz logic.
- **Audit:** Skyflow logs detokenize/re-identify events with the policy context,
  giving a tamper-evident record of *who re-identified what* — something the
  gateway alone can't provide.
- **Entity treatment** (`plain_text`/`masked`/`redacted`) is a gateway-side
  guardrail layered on top of vault policy: even an authorized re-identify can
  be down-graded to masked for specific entity classes per Route/Consumer.

## 7.6 Compliance posture

- **GDPR / CCPA:** supports data minimization (providers process tokens, not
  identities) and purpose limitation (per-Route entity sets); right-to-erasure
  is handled in the vault, not the gateway.
- **HIPAA:** PHI entities (MRN, name, DOB, etc.) can be tokenized before reaching
  a model; the model/provider is removed from PHI scope for tokenized fields.
- **PCI DSS:** PAN (`CREDIT_CARD`) tokenized before egress; re-identify can keep
  it `masked` even on the return path.
- These are *enabled by* the architecture; formal attestations depend on the
  Skyflow vault configuration and the surrounding deployment, not this plugin
  alone.

## 7.7 Privacy invariants (enforced in CI)

Restated from [`testing §6.5`](../contributing/testing.md#65-security--privacy-tests-must-pass-invariants),
these are release-gating:

1. No PII reaches the upstream on any `deny` error path.
2. No PII appears in logs or metrics.
3. No PII persists in any cache or on disk.
4. Credentials never returned by the Admin API.
5. `masked`/`redacted` entities never returned in plaintext.
6. Auth failures (401/403) never fall through to forwarding raw data.

## 7.8 Operational security guidance

- Run data planes with outbound egress limited to the Skyflow cluster +
  intended upstreams.
- Keep `ssl_verify` on for Skyflow; use system or pinned CA bundle.
- Set `dry_run=true` during initial rollout to observe detections without
  altering traffic, then flip to enforcing (see [`operations`](operations.md)).
- Alert on `skyflow_*_error` rate and on `posture=allow` events (a fail-open
  event is a privacy-relevant signal).
