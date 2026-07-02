# 05 — Implementation Plan

A phased plan to take the plugin from this spec to a tested, packaged, releasable
artifact. Each phase has an objective, deliverables, and an exit/acceptance gate.

## 5.1 Repository layout (target)

```
skyflow-kong-poc/
├── kong/plugins/skyflow-deidentify/        # the plugin (LuaRocks-discoverable path)
│   ├── handler.lua
│   ├── schema.lua
│   ├── auth.lua
│   ├── client.lua
│   ├── body.lua
│   └── mapping.lua
├── spec/skyflow-deidentify/                # busted specs
│   ├── 01-schema_spec.lua
│   ├── 02-access_spec.lua
│   ├── 03-response_spec.lua
│   ├── 04-auth_spec.lua
│   ├── 05-body_spec.lua
│   └── helpers/mock_skyflow.lua
├── skyflow-deidentify-0.1.0-1.rockspec
├── .pongo/pongo-compose.yml                # optional services for Pongo
├── .busted                                 # busted config
├── .luacheckrc                             # lint config
├── docker-compose.yml                      # local Kong + mock Skyflow for manual e2e
├── Makefile                                # dev ergonomics (lint/test/pack)
└── docs/                                   # this specification
```

> The reference skeleton in this repo lives under `plugin/` to keep it clearly
> labeled as *reference*. Phase 1 promotes it to the top-level `kong/plugins/...`
> path that LuaRocks and `KONG_PLUGINS` expect.

## 5.2 Dependencies & packaging

`skyflow-deidentify-0.1.0-1.rockspec` (see [reference rockspec](../plugin/kong/plugins/skyflow-deidentify/skyflow-deidentify-0.1.0-1.rockspec)):

```lua
dependencies = {
  "lua >= 5.1",
  -- lua-resty-http ships with Kong/OpenResty; pinned here for standalone installs
  "lua-resty-http >= 0.17",
  -- ONLY required when service-account JWT auth is used:
  "lua-resty-jwt >= 0.2.3",
}
```

- `cjson`, `resty.*`, `lua-resty-lock` are provided by the Kong/OpenResty
  runtime — not vendored.
- For SA-JWT, prefer `resty.openssl` (bundled in modern Kong) for RS256 signing
  to avoid the extra rock; `lua-resty-jwt` listed as the portable fallback.

## 5.3 Phases

### Phase 0 — Project scaffolding *(0.5 day)*

- **Objective:** repo builds, lints, and runs an empty test.
- **Deliverables:** rockspec, `.luacheckrc`, `.busted`, `Makefile`
  (`make lint test pack`), CI skeleton (§5.5), `docker-compose.yml` placeholder.
- **Gate:** `make lint test` green on an empty plugin; `luarocks make` packs.

### Phase 1 — Schema + plugin loads *(1 day)*

- **Objective:** Kong loads the plugin; config validates.
- **Deliverables:** `schema.lua` (all fields, entity checks from
  [`docs/04 §4.3.7`](04-plugin-spec.md#4317-schema-level-validation-entity-checks)),
  minimal `handler.lua` (PRIORITY/VERSION + no-op phases).
- **Gate:** `01-schema_spec.lua` passes (valid/invalid configs, mutually-
  exclusive credentials, referenceable+encrypted fields); plugin appears in
  `GET /plugins/enabled`.

### Phase 2 — Skyflow client + auth *(2 days)*

- **Objective:** talk to Skyflow (against the mock first, then a sandbox vault).
- **Deliverables:** `auth.lua` (api_key + SA-JWT + caching/single-flight),
  `client.lua` (`deidentify`, `reidentify`, `detokenize`; timeouts, retries,
  error mapping, keepalive pool).
- **Gate:** `04-auth_spec.lua` (token mint/cache/refresh/401-retry) and client
  unit tests pass against `mock_skyflow.lua`; a manual smoke test against a real
  Skyflow **sandbox** de-identifies a sample string.

### Phase 3 — De-identify path *(2 days)*

- **Objective:** request bodies are de-identified end-to-end.
- **Deliverables:** `body.lua` (openai/anthropic/mcp/generic profiles, JSONPath
  subset, extract/replace), `handler.access` (steps in
  [`docs/04 §4.4`](04-plugin-spec.md#access-conf)), mapping capture, postures.
- **Gate:** `02-access_spec.lua` + `05-body_spec.lua` pass: tokenized body sent
  upstream, `Content-Length` correct, fail-closed on Skyflow error, dry-run
  leaves body intact, oversized/non-JSON handled.

### Phase 4 — Re-identify path *(2 days)*

- **Objective:** responses are re-hydrated for authorized callers.
- **Deliverables:** `handler.response` (buffered), all three strategies
  (`reidentify_text`, `detokenize`, `mapping_only`), entity treatment,
  streaming `buffer`/`passthrough`.
- **Gate:** `03-response_spec.lua` passes: tokens restored per treatment,
  `return_tokenized` degradation on error, streaming-buffer correctness, no
  re-identify when disabled (and no buffering imposed then).

### Phase 5 — Observability & resilience *(1 day)*

- **Objective:** production signals + bounded behavior.
- **Deliverables:** `log.lua` metrics (counts/latency/error class), deadline
  enforcement, concurrency caps, Prometheus/StatsD-friendly counters.
- **Gate:** metrics emitted with **no** PII; chaos tests (inject Skyflow
  timeouts/5xx/429) respect deadline and posture.

### Phase 6 — Streaming reassembler (experimental) *(2 days, optional)*

- **Objective:** incremental re-identify for SSE.
- **Deliverables:** `body_filter` build-flagged variant with partial-token
  buffering + flush-on-finish.
- **Gate:** SSE conformance tests (tokens split across chunks reassembled
  correctly; final flush complete).

### Phase 7 — Packaging, docs, examples *(1 day)*

- **Objective:** installable and demoable.
- **Deliverables:** finalized rockspec, decK/Konnect/KIC/Terraform examples
  ([`docs/08`](08-operations.md)), `docker-compose` e2e demo (Kong + mock
  Skyflow + echo upstream), README quickstart verified.
- **Gate:** `luarocks install` into a clean Kong image; demo script runs the
  worked example from [`docs/03 §3.9`](03-skyflow-integration.md#39-worked-end-to-end-example-openai-profile-de-identify--re-identify).

**Critical path:** P0→P1→P2→P3 delivers a usable de-identify-only plugin (the
most common posture). P4 adds re-identify. P5 hardens. P6 is optional polish.

## 5.4 Effort & sequencing summary

| Phase | Focus | Est. | Depends on |
| ----- | ----- | ---- | ---------- |
| 0 | Scaffolding | 0.5d | — |
| 1 | Schema + load | 1d | 0 |
| 2 | Skyflow client/auth | 2d | 1 |
| 3 | De-identify | 2d | 2 |
| 4 | Re-identify | 2d | 3 |
| 5 | Observability/resilience | 1d | 3 |
| 6 | Streaming (opt) | 2d | 4 |
| 7 | Packaging/docs | 1d | 3 (4,5 ideally) |

MVP (de-identify only, tested, packaged): **P0–P3 + P7 ≈ 6.5 days**.
Full v1 (with re-identify + hardening): **+P4,P5 ≈ 9.5 days**.

## 5.5 CI pipeline

GitHub Actions (extends the existing workflow dir):

1. **lint** — `luacheck kong spec`.
2. **unit** — `busted spec` with `mock_skyflow.lua` (no network).
3. **integration** — `pongo run` matrix across Kong versions
   (`3.4`, `3.10`, latest) to catch PDK drift.
4. **package** — `luarocks make`/`pack`; upload the `.rock` artifact.
5. **security** — `luacheck` + dependency review; secret-scan to ensure no
   credentials/fixtures with real PII are committed.

CI must be **hermetic**: all Skyflow interactions hit the in-repo mock; a
separate, **manual** `sandbox-smoke` workflow (guarded by an environment) runs
against a real Skyflow sandbox using repo secrets.

## 5.6 Acceptance criteria for v1 (de-identify + re-identify)

- All specs in [`docs/06`](06-testing.md) pass on the Kong version matrix.
- Conformance matrix ([`docs/06 §6.6`](06-testing.md#66-conformance-matrix)) green.
- Fail-closed verified: no test path forwards raw PII upstream on any Skyflow
  error when `on_skyflow_error = deny`.
- No PII in logs/metrics (asserted by a dedicated test).
- Latency overhead within budget ([`docs/08 §8.4`](08-operations.md#84-latency-budget))
  on the perf harness.
- Installs via LuaRocks into a stock Kong image and configures via decK.
