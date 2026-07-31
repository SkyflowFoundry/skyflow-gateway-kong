# Operations

Configuration recipes, observability, performance budgets, and rollout guidance.

## Installation

```bash
# Into a Kong node / image
luarocks install skyflow-deidentify        # or: luarocks make ./*.rockspec

# Tell Kong to load it
export KONG_PLUGINS=bundled,skyflow-deidentify
# (or kong.conf: plugins = bundled,skyflow-deidentify)

kong reload
```

Confirm: `curl localhost:8001/plugins/enabled | jq '.enabled_plugins[]' | grep skyflow`.

## Configuration examples

### decK (de-identify only — most common)

```yaml
_format_version: "3.0"
services:
  - name: openai
    url: https://api.openai.com:443
    routes:
      - name: chat
        paths: ["/v1/chat/completions"]
    plugins:
      - name: skyflow-deidentify
        config:
          vault_id: "${SKYFLOW_VAULT_ID}"
          cluster_id: "${SKYFLOW_CLUSTER_ID}"
          credentials:
            api_key: "{vault://env/SKYFLOW_API_KEY}"
          profile: openai
          deidentify:
            entities: [NAME, SSN, CREDIT_CARD, EMAIL_ADDRESS, PHONE_NUMBER]
            token_format: VAULT_TOKEN
          on_skyflow_error: deny
```

### decK (de-identify + re-identify, composed with AI Proxy — nested proxy)

`skyflow-deidentify` and `ai-proxy` **cannot share a route** (Kong #14380 — see
[`architecture.md §2.8`](../contributing/architecture.md#28-deployment-topologies)).
Use two routes: a **front route** runs de-identify + re-identify and proxies
(loopback) to an **internal route** that runs `ai-proxy` alone.

```yaml
services:
  - name: ai-front
    url: http://127.0.0.1:8000/_ai_upstream   # loopback to the internal route
    routes:
      - name: ai-chat
        paths: ["/ai/chat"]
    plugins:
      - name: skyflow-deidentify
        config:
          vault_id: "${SKYFLOW_VAULT_ID}"
          cluster_id: "${SKYFLOW_CLUSTER_ID}"
          credentials: { api_key: "{vault://env/SKYFLOW_API_KEY}" }
          profile: openai
          deidentify: { entities: [NAME, EMAIL_ADDRESS, PHONE_NUMBER], token_format: VAULT_TOKEN }
          reidentify: { enabled: true, strategy: reidentify_text, default_treatment: plain_text }
          on_skyflow_error: deny
  - name: ai-upstream
    url: http://localhost:32000               # placeholder; ai-proxy overrides upstream
    routes:
      - name: ai-upstream
        paths: ["/_ai_upstream"]              # restrict in prod so it can't be called directly
    plugins:
      - name: ai-proxy
        config: { route_type: "llm/v1/chat", model: { provider: openai, name: gpt-4o-mini } }
```

A ready-to-run version is in
[`deploy/konnect-hybrid/deck/real-vault.yaml`](../../deploy/konnect-hybrid/deck/real-vault.yaml).

### Admin API

```bash
curl -X POST http://localhost:8001/routes/chat/plugins \
  --data name=skyflow-deidentify \
  --data config.vault_id=$SKYFLOW_VAULT_ID \
  --data config.cluster_id=$SKYFLOW_CLUSTER_ID \
  --data config.credentials.sts.service_account_id=$SKYFLOW_STS_SERVICE_ACCOUNT_ID \
  --data config.profile=mcp \
  --data 'config.deidentify.entities=NAME,EMAIL_ADDRESS'
```

### Kubernetes (KIC)

```yaml
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata: { name: skyflow-deidentify, namespace: ai }
plugin: skyflow-deidentify
config:
  vault_id: { valueFrom: { secretKeyRef: { name: skyflow, key: vault_id } } }
  cluster_id: { valueFrom: { secretKeyRef: { name: skyflow, key: cluster_id } } }
  credentials: { api_key: "{vault://k8s/skyflow/api-key}" }
  profile: openai
  deidentify: { entities: [NAME, EMAIL_ADDRESS], token_format: VAULT_TOKEN }
# annotate the Ingress/HTTPRoute/Service: konghq.com/plugins: skyflow-deidentify
```

### Konnect

Same `config` block via the Konnect control-plane API/UI; inject credentials as
control-plane secrets and let data planes resolve the `{vault://…}` references.

## Observability

When `log.detections = true`, the plugin adds these fields to Kong's log
serializer in the `log` phase (they flow to whatever logging/analytics you run —
Konnect analytics, file-log, http-log, etc.):

- `skyflow.entities_by_type` — per-request counts of detected entities by class.
- `skyflow.posture` — the posture taken for the request (`enforce` / `allow`).

**Values are never logged** — only counts, types, and posture.

What to watch:

- A rise in de-identify failures / `502`s → Skyflow degradation (check egress,
  DNS, and TLS to the vault cluster).
- Any `skyflow.posture = allow` when you run `on_skyflow_error = deny` → a
  fail-open slipped through; treat as a privacy-relevant signal.

> Dedicated Prometheus/StatsD counters (request outcomes, Skyflow latency, error
> classes) are a planned enhancement; today, derive signals from the fields above
> plus Kong's built-in request metrics.

## Latency budget

Added latency ≈ Skyflow round-trips (API-key auth adds no extra round-trip — the
key is sent directly):

| Posture | Extra round-trips | Typical added p95* |
| ------- | ----------------- | ------------------ |
| de-identify only | 1 (batched/concurrent) | ~1× Detect RTT |
| + reidentify_text | 2 | ~2× Detect RTT |
| + mapping_only re-identify | 1 | ~1× Detect RTT (no 2nd call) |

\*Excludes the LLM/upstream time, which usually dominates. Tuning levers:

- `batch_mode=per_span` + `max_concurrency` to keep multi-message prompts at
  ~one RTT.
- `mapping_only` to avoid the second Skyflow call entirely when applicable.
- keepalive pool sizing (`keepalive_pool_size`) to avoid TLS handshakes.
- co-locate data planes near the Skyflow cluster region.
- `deadline_ms` to bound worst case; `reidentify.on_error=return_tokenized` so
  re-identify slowness never fails the user-visible call.

Because Skyflow I/O is non-blocking (cosockets), added latency does **not**
proportionally reduce worker throughput.

## Rollout playbook

1. **Observe (`dry_run=true`):** enable on a Route; the plugin detects and logs
   entity counts but does **not** alter traffic. Validate detection coverage and
   latency.
2. **Enforce de-identify (`dry_run=false`, `reidentify.enabled=false`):** start
   tokenizing outbound traffic; `on_skyflow_error=deny`. Watch error/posture
   metrics. Streaming unaffected.
3. **Enable re-identify** for the responses that need it; start with
   `entity_treatment` conservative (mask high-sensitivity classes), `streaming=
   buffer`. Validate UX.
4. **Tune:** adjust entities, batching, concurrency, treatments; consider
   `mapping_only` for latency-sensitive routes.
5. **Scale out:** roll to more Routes/Services or go global on an egress gateway.

Rollback is a config flip (`dry_run=true` or disable the plugin) — no data
migration, no schema/DAO state.

## Capacity & limits

- Memory: bounded by `max_body_size` × in-flight requests; size workers
  accordingly for large prompts.
- HTTP connections to Skyflow are pooled per worker (`keepalive_pool_size`) to
  avoid a TLS handshake on every call.
- For very large corpora or file modalities, prefer an async pipeline over the
  synchronous proxy path (not supported today; see [overview](overview.md#non-goals)).

## Troubleshooting

| Symptom | Likely cause | Action |
| ------- | ------------ | ------ |
| 502 on de-identify | Skyflow unreachable/slow (fail-closed) | check egress/DNS/TLS to the vault cluster; raise `timeout_ms`/`deadline_ms`; verify region. |
| 403 from Skyflow | the API key's role lacks the Detect permission | grant Detect de-identify (and reidentify, if you re-identify). |
| Upstream still sees PII | de-identify not on the request path, or wrong profile/paths | with `ai-proxy`, use the nested-proxy layout (de-identify on the front route; see the nested-proxy example above); verify `profile`/`request_json_paths`. |
| Re-identify not happening | `reidentify.enabled=false`, streamed + `passthrough`, or `mapping_only` missing tokens | enable it; use `buffer`; check the token source. |
| Credential visible concern | — | credentials are `encrypted`+`referenceable`; confirm `GET /plugins` returns no raw secret. |
| High latency | no keepalive / serial batching | raise `keepalive_pool_size`; use `per_span` concurrency or `mapping_only`; co-locate near the vault region. |
