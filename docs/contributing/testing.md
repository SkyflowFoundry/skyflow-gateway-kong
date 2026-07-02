# Testing Strategy

Testing is first-class: a privacy control that occasionally leaks is worse than
none, so the suite is built to **prove** the security invariants, not just happy
paths. We use Kong's standard tooling — **busted** (test runner), **Pongo**
(spins up Kong + dependencies in Docker), and an **in-repo mock** of the Skyflow
Detect API so the bulk of tests run hermetically with no network or live vault.

## 6.1 Test pyramid

```
        ┌───────────────────────────────┐
        │  e2e (docker-compose, manual)  │  Kong + mock Skyflow + echo upstream
        ├───────────────────────────────┤  + guarded sandbox-smoke vs real vault
        │  integration (Pongo + busted)  │  real Kong, mocked Skyflow HTTP
        ├───────────────────────────────┤
        │  unit (busted)                 │  body.lua, auth.lua, client.lua,
        └───────────────────────────────┘  mapping.lua, schema entity checks
```

## 6.2 Tooling & layout

- **busted** with Kong's `spec.helpers` for integration tests; pure busted for
  unit tests.
- **Pongo** (`kong-pongo`) to run the integration suite against a matrix of Kong
  versions and to inject dependency services.
- **`.busted`**, **`.luacheckrc`** committed; `make test` / `make lint` wrap them.
- Specs under `spec/skyflow-deidentify/` (see reference skeletons in this repo).

### The Skyflow mock (`helpers/mock_skyflow.lua`)

A tiny HTTP server (Kong `http_mock` / a `mockbin`-style Service, or an OpenResty
`content_by_lua` server started by the spec) that emulates the Detect API:

- `POST /v1/detect/deidentify/string` → deterministic tokenization: replaces
  known fixtures (`Jane Doe`→`[NAME_aB3xQ]`, …) and echoes an `entities[]` map.
- `POST /v1/detect/reidentify/string` → inverse mapping.
- `POST /v1/vaults/{id}/detokenize` → token→value lookup.
- `POST {tokenURI}` → returns a signed-looking `accessToken` with short
  `expiresIn` to exercise refresh.
- **Fault injection** via request headers/paths: `x-mock-fault: timeout|500|401|
  429|garbage` so resilience tests deterministically trigger each branch.

This keeps unit + integration tests **hermetic, deterministic, and fast**.

## 6.3 Unit tests

| Spec | Module | Key cases |
| ---- | ------ | --------- |
| `01-schema_spec.lua` | `schema.lua` | valid full config; missing `vault_id`/`cluster_id`; **exactly-one-of** credentials (none / two ⇒ invalid); `mapping_only` + `ENTITY_ONLY` ⇒ invalid; `deadline_ms < timeout_ms` ⇒ invalid; `generic` without paths ⇒ invalid; referenceable+encrypted credential fields accept `{vault://…}`. |
| `04-auth_spec.lua` | `auth.lua` | api_key path sets header; SA-JWT builds correct claims & RS256-signs; token cached & reused; refresh at `expiry−skew`; **single-flight** under concurrent misses (one mint); 401 ⇒ one forced refresh+retry. |
| `client_spec.lua` | `client.lua` | request body matches [`skyflow-integration §3.3`](skyflow-integration.md#33-de-identify-operation); timeout/5xx/429 ⇒ `retryable`; 403 ⇒ non-retryable + clear error; non-JSON ⇒ error; deadline halts retries; keepalive reused. |
| `05-body_spec.lua` | `body.lua` | each profile extracts the right spans (incl. OpenAI array-content form, MCP `arguments.*`, Anthropic `system`); JSONPath subset (`$.a.b`, `[*]`, `[n]`, string-leaf recursion); non-string leaves skipped; replace is exact & order-independent; `text` content-type whole-body; malformed JSON ⇒ error. |
| `mapping_spec.lua` | `mapping.lua` | put/get round-trip; entity counts; isolation (a new ctx is empty); never serializes values to a shared store. |

## 6.4 Integration tests (Pongo + `spec.helpers`)

Run real Kong with the plugin enabled, pointed at the **mock Skyflow** Service.

| Spec | Scenario | Assertions |
| ---- | -------- | ---------- |
| `02-access_spec.lua` | de-identify only, `openai` profile | upstream (echo) receives **tokenized** `messages[*].content`; original PII absent from upstream-seen body; `Content-Length` correct; client still gets a 200. |
| | fail-closed | mock returns `500`/timeout, `on_skyflow_error=deny` ⇒ client gets **502**, upstream **never called** with raw body. |
| | fail-open | same fault, `allow` ⇒ original body forwarded, warn logged. |
| | dry_run | body **unchanged** upstream, but detection metrics/logs present. |
| | non-JSON / oversized | `on_parse_error` posture respected. |
| | `mcp` profile | JSON-RPC `params.arguments.*` tokenized; non-string params untouched. |
| `03-response_spec.lua` | re-identify `reidentify_text` | response `choices[*].message.content` restored; `entity_treatment` (name plain, card masked) honored. |
| | `detokenize` strategy | targeted fields detokenized; redaction levels respected. |
| | `mapping_only` | no second Skyflow call (mock asserts zero `/reidentify` hits); tokens from the request restored; foreign tokens left intact. |
| | reidentify error | `return_tokenized` ⇒ client gets tokenized 200 (not 5xx); `deny` ⇒ configured failure. |
| | streaming `buffer` | `stream:true` upstream SSE is buffered, re-identified, returned complete. |
| | streaming `passthrough` | stream passes through untouched; not buffered. |
| | disabled | `reidentify.enabled=false` ⇒ **no buffering** imposed (assert streaming works), response untouched. |
| `ordering_spec.lua` | composition | with `ai-proxy` + dynamic ordering, de-identify runs before proxy (upstream sees tokens), re-identify after. |

## 6.5 Security & privacy tests (must-pass invariants)

These encode the product's promises and gate every release:

1. **No-leak-upstream:** for every error branch with `deny`, assert the upstream
   mock recorded **no** request containing any fixture PII value.
2. **No-PII-in-logs:** capture `kong.log` output + metrics during a run with rich
   PII fixtures; assert none of the fixture values appear. (Counts/entity types
   only.)
3. **No-PII-at-rest:** assert the bearer-token cache and any `kong.cache` entries
   contain no fixture values; mapping exists only on `kong.ctx.plugin`.
4. **Credential redaction:** `GET /plugins/<id>` never returns raw
   `api_key`/`token`/`service_account_json` (encrypted/referenceable).
5. **Treatment honored:** entities configured `masked`/`redacted` are **never**
   returned in plaintext to the client even on the re-identify path.
6. **Auth-failure-never-falls-through:** 401/403 always denies (never forwards
   raw body), regardless of `on_skyflow_error`.

## 6.6 Conformance matrix

| Dimension | Values exercised |
| --------- | ---------------- |
| Kong version | 3.4 LTS, 3.10 LTS, latest |
| Profile | openai, anthropic, mcp, generic |
| Content-type | json (object & array message forms), text |
| Token format | VAULT_TOKEN, ENTITY_ONLY, ENTITY_UNQ_COUNTER |
| Reidentify | off, reidentify_text, detokenize, mapping_only |
| Streaming | non-stream, buffer, passthrough |
| Posture | deny, allow; on_parse_error deny/skip |
| Auth | api_key, service-account JWT |
| Fault | none, timeout, 500, 401, 429, garbage |

A representative cross-product runs in CI; the full matrix runs nightly.

## 6.7 Performance tests

- **Harness:** `wrk`/`k6` against `docker-compose` (Kong + mock Skyflow with a
  fixed simulated latency + echo upstream).
- **Metrics:** added p50/p95/p99 latency vs a no-plugin baseline; throughput;
  worker memory under sustained load; token-cache hit ratio (expect ≈100% after
  warm-up); single-flight verified (one token mint under a cold-start burst).
- **Budgets:** see [`operations §8.4`](../using/operations.md#84-latency-budget). Perf
  job fails if p95 overhead exceeds budget at target RPS.

## 6.8 Local developer loop

```bash
make lint            # luacheck
make test            # busted unit + Pongo integration (mock Skyflow)
make e2e             # docker-compose: Kong + mock Skyflow + echo; runs demo script
make sandbox-smoke   # OPTIONAL: against a real Skyflow sandbox (needs creds)
```

`make test` requires only Docker — **no Skyflow account** — so contributors and
CI run the full functional suite offline.
