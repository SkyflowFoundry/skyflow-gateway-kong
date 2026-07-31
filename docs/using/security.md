# Security & Governance

The plugin *is* a security control, so its own posture matters. This covers the
threat model, data handling, secrets, governance, and compliance.

## Security objectives

- **No raw sensitive data reaches the upstream** (LLM/MCP/API) when de-identify
  is active — the core promise, backed by a fail-closed default.
- **Re-identification is governed by Skyflow** (roles, policies, audit) — the
  gateway can't reveal more than policy permits.
- **No sensitive data persists at the gateway** — no disk, no shared cache, no
  logs.
- **Credentials are protected** at rest and in transit, and never exposed via the
  Admin API.
- **Fail closed** — faults degrade toward *less* exposure, never more.

## Threat model

| Threat | Vector | Mitigation |
| --- | --- | --- |
| **Data exfiltration to provider** | PII forwarded before tokenization | De-identify in `access` before the request is proxied; fail-closed by default; auth failures always deny. |
| **Leak via logs** | Values printed in debug/error logs | Logs carry counts/types/posture only — never values; error paths log messages, not bodies. |
| **Leak via cache/state** | Plaintext written to `kong.cache`/disk | No plaintext is cached; the token↔value map lives only in `kong.ctx.plugin` for the request. |
| **Credential theft** | Reading plugin config / DB / Admin API | Credentials are `encrypted` + `referenceable` (`{vault://…}`); never returned by `GET /plugins`. |
| **Unauthorized re-identification** | Caller restores data they shouldn't | Skyflow role governs what the credential may re-identify; `entity_treatment` masks/redacts even on the return path; `mapping_only` avoids any vault detokenize. |
| **Token forgery / replay** | Crafted tokens in a response | `mapping_only` restores only tokens minted **this** request; vault-backed re-identify is governed by Skyflow policy regardless of token origin. |
| **MITM to Skyflow** | Network interception | TLS to `*.vault.skyflowapis.com`; certificate verification on (never `ssl_verify=false` in prod). |
| **DoS / amplification** | Huge bodies, many spans | `max_body_size`, `max_spans`, `max_concurrency`, `deadline_ms`; oversized ⇒ configured posture. |
| **PII reaches upstream before tokenization** | Plugin not on the request path | De-identify runs in `access`; with `ai-proxy` the nested-proxy topology keeps de-identify on the front route so the internal `ai-proxy` route only ever sees tokens. |
| **Credential compromise** | Gateway host compromised | Nothing to steal: the gateway holds no Skyflow credential. Access requires a live caller IdP token, and the vault enforces that caller's own entitlements. |

## Data handling & residency

- **In memory only.** Request/response bodies and the token↔value map exist only
  in worker memory for the request's lifetime, then are garbage-collected.
- **PII egress is to the vault only.** The single external destination that sees
  raw values is Skyflow, over TLS. The upstream sees tokens.
- **Residency** follows the Skyflow vault region (`cluster_id`), not the gateway.
  For data-residency needs, target the in-region cluster (or pin
  `skyflow_base_url_override` to a regional/private endpoint).
- **No analytics on values.** Emitted signals are aggregate counts by entity type.

## Secrets management

- Credentials are schema-typed `encrypted` + `referenceable`, so they're never
  stored in plaintext and never returned by the Admin API.
- There is no Skyflow credential to provide. STS delegation (RFC 8693) is the only credential path: the caller's enterprise IdP token is exchanged for a short-lived Skyflow bearer whose `ctx` is their signed claims. The gateway holds **no** Skyflow credential -- no API key, no service account, no private key -- so there is nothing here for an attacker who compromises the host to steal.
  reference — Kong **Secrets Management** (`{vault://env/...}`, HashiCorp Vault,
  AWS/GCP SM) or a Konnect control-plane secret.
- Nothing to rotate at the gateway. Revoking the caller's IdP session, or the STS issuer trust in the Skyflow account, removes access.
  needed.

### Service-account JWT auth (recommended)

`credentials.sts` names the delegating service account and the expected issuer and audience; it contains no secret.
JSON. The gateway signs an RS256 JWT assertion in-process (Kong-bundled
`resty.openssl`; the private key never leaves the data plane) and exchanges it
for a short-lived bearer (~60 min), cached per worker and re-minted
`token_skew_seconds` before expiry. Two levers shape each bearer:

- **Scoped tokens** — `credentials.role_ids` restricts the bearer to a subset of
  the SA's roles (`scope: "role:<id> ..."` on the exchange).
- **Context-aware authorization** — the assertion's `ctx` claim accepts
  arbitrary JSON (vault policies traverse it as `$ctx.a.b`) and is assembled in
  layers, later layers winning:
  1. `credentials.context_json` — raw JSON string, any shape (nested objects,
     booleans, numbers); the ctx base. Referenceable like other secrets.
  2. `credentials.context` — static `attr → string` map; dot-delimited attrs
     nest (`org.unit → ctx.org.unit`).
  3. `credentials.context_headers` — `attr → request header`, resolved per
     request. **Client-supplied** — treat as untrusted unless an upstream
     gateway strips/sets the header.
  4. `credentials.context_kong` — `attr → gateway-derived fact`
     (`consumer_id`/`consumer_username`/`consumer_custom_id`/`route_name`/
     `service_name`/`client_ip`), resolved via the PDK. **Trusted and merged
     last**, so a client header can never override these attributes.

  Skyflow embeds the merged object in the bearer, so vault policies can
  condition access per caller: `ALLOW READ ON ... WHERE table.owner =
  $ctx.caller.user`. Distinct resolved contexts mint distinct cached bearers,
  and the full context is audit-logged by Skyflow (the audit event's Context
  ID). To make enforcement mandatory, set `enforceContextID: true` on the
  service account — token exchange then fails unless `ctx` is present.

## Governance & RBAC (delegated to Skyflow)

Authorization of data exposure is delegated to Skyflow so policy is centralized
and audited:

- **Least privilege** — the credential's Skyflow role is granted only the Detect
  permissions it needs (de-identify; re-identify only if used). A de-identify-only
  deployment need not hold re-identify rights.
- **Audit** — Skyflow logs re-identify/detokenize events, giving a record of
  *who re-identified what* that the gateway alone can't provide.
- **Gateway-side guardrail** — `entity_treatment` (`plain_text`/`masked`/
  `redacted`) can down-grade even an authorized re-identify per entity class,
  Route, or Consumer.
- **Tool-input containment** — `reidentify.tool_inputs` controls what agents'
  tools receive in `tool_calls`/`tool_use` inputs. Default `tokenized`: the
  gateway is the trust boundary, tools egress to arbitrary services (web
  search, APIs, files), so tokens stay tokens inside agent-land and real
  values only materialize at the gateway on authorized paths. `plain_text`
  restores values before tool execution for trust-the-client deployments.
  Chat text returned to the caller is unaffected (governed by
  `strategy`/`entity_treatment` as before).

> Per-caller policy context (scoped tokens carrying consumer/department `ctx` for
> attribute-based re-identification decisions) is available via service-account
> JWT auth — see [Service-account JWT auth](#service-account-jwt-auth-recommended).

## Compliance posture

- **GDPR / CCPA** — data minimization (providers process tokens, not identities)
  and purpose limitation (per-Route entity sets); right-to-erasure lives in the
  vault.
- **HIPAA** — PHI entities can be tokenized before reaching a model, removing the
  provider from PHI scope for tokenized fields.
- **PCI DSS** — PAN (`CREDIT_CARD`) tokenized before egress; re-identify can keep
  it `masked` on the return path.

These are *enabled by* the architecture; formal attestations depend on the
Skyflow vault configuration and the surrounding deployment, not this plugin alone.

## Privacy invariants

The design upholds these invariants (and they're the assertions the test suite
targets — see [testing](../contributing/testing.md#65-security--privacy-tests-must-pass-invariants)):

1. No PII reaches the upstream on any `deny` error path.
2. No PII appears in logs.
3. No PII persists in any cache or on disk.
4. Credentials are never returned by the Admin API.
5. `masked`/`redacted` entities are never returned in plaintext.
6. Auth failures (401/403) never fall through to forwarding raw data.

## Operational security guidance

- Limit data-plane egress to the Skyflow cluster + intended upstreams.
- Keep `ssl_verify` on for Skyflow; use a system or pinned CA bundle.
- Roll out with `dry_run: true` to observe detections without altering traffic,
  then enforce (see [operations](operations.md#rollout-playbook)).
- Treat any fail-open (`skyflow.posture = allow` when configured `deny`) as a
  privacy-relevant signal to alert on.
