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
| **Credential compromise** | Gateway host compromised | Nothing to steal under the default `method: sts`; `jwt_credential` and `bearer_token` do place one on the gateway. Access requires a live caller IdP token, and the vault enforces that caller's own entitlements. |

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
- **Under the default `method: sts` there is no Skyflow credential to provide.**
  The caller's enterprise IdP token is exchanged (RFC 8693) for a short-lived
  Skyflow bearer whose `ctx` is their signed claims, so the gateway holds no API
  key, no service account and no private key — nothing for an attacker who
  compromises the host to steal, and nothing to rotate at the gateway. Revoking
  the caller's IdP session, or the STS issuer trust in the Skyflow account,
  removes access.
- **The other two methods do put a credential on the gateway**, and it must be a
  secret reference — Kong **Secrets Management** (`{vault://env/...}`, HashiCorp
  Vault, AWS/GCP SM) or a Konnect control-plane secret — never inline.
  `jwt_credential` holds an RSA private key; `bearer_token` holds a long-lived
  API key whose compromise is indistinguishable from legitimate use, because the
  vault sees no caller identity under that method.

### Choosing an auth method

`credentials.method` is one of `sts` (default), `jwt_credential`, `bearer_token`.
They differ in what the vault learns about who is asking, which is what your vault
policies can act on.

| Method | Credential on the gateway | Identity the vault sees | `ctx` |
| --- | --- | --- | --- |
| `sts` | none | the caller's own IdP-signed token | the IdP's claims |
| `jwt_credential` | RSA private key | asserted by the gateway | derived by the plugin |
| `bearer_token` | long-lived API key | none | none |

`jwt_credential` takes exactly one field, `service_account_json`. There is no ctx
configuration under any method: the plugin derives `ctx` itself from
`kong_consumer` (present only when a Kong auth plugin verified the client),
`kong_client_ip`, `kong_request_id`, `kong_route` and `kong_service`. Verified
against the live Skyflow token endpoint — the claim is propagated verbatim into
the minted bearer, so vault policies can key on `$ctx.kong_route` and friends.

An earlier build let operators map request **headers** into `ctx`. That was
removed rather than documented: it fed values the caller controls into the claim
set the vault trusts for policy decisions, so anyone able to reach the gateway
could assert their own tenant or purpose.

Note the ceiling: under `jwt_credential` there is no caller identity at all, so
`ctx` describes the gateway, never the person. Per-user vault policy requires
`sts`.

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
> JWT auth — see [Choosing an auth method](#choosing-an-auth-method).

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
