# 08 — Operations

Configuration recipes, observability, performance budgets, and rollout guidance.

## 8.1 Installation

```bash
# Into a Kong node / image
luarocks install skyflow-deidentify        # or: luarocks make ./*.rockspec

# Tell Kong to load it
export KONG_PLUGINS=bundled,skyflow-deidentify
# (or kong.conf: plugins = bundled,skyflow-deidentify)

kong reload
```

Confirm: `curl localhost:8001/plugins/enabled | jq '.enabled_plugins[]' | grep skyflow`.

## 8.2 Configuration examples

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

### decK (de-identify + re-identify, composed with AI Proxy)

```yaml
plugins:
  - name: skyflow-deidentify
    config:
      vault_id: "${SKYFLOW_VAULT_ID}"
      cluster_id: "${SKYFLOW_CLUSTER_ID}"
      credentials:
        service_account_json: "{vault://hcv/skyflow/sa}"
      profile: openai
      deidentify: { entities: [NAME, EMAIL_ADDRESS, PHONE_NUMBER], token_format: VAULT_TOKEN }
      reidentify:
        enabled: true
        strategy: reidentify_text
        default_treatment: plain_text
        entity_treatment: { CREDIT_CARD: masked, SSN: redacted }
        streaming: buffer
    ordering:
      before:
        access: [ai-proxy, ai-proxy-advanced]
  - name: ai-proxy
    config: { route_type: "llm/v1/chat", model: { provider: openai } }
```

### Admin API

```bash
curl -X POST http://localhost:8001/routes/chat/plugins \
  --data name=skyflow-deidentify \
  --data config.vault_id=$SKYFLOW_VAULT_ID \
  --data config.cluster_id=$SKYFLOW_CLUSTER_ID \
  --data config.credentials.api_key=$SKYFLOW_API_KEY \
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
  credentials: { service_account_json: "{vault://k8s/skyflow/sa}" }
  profile: openai
  deidentify: { entities: [NAME, EMAIL_ADDRESS], token_format: VAULT_TOKEN }
# annotate the Ingress/HTTPRoute/Service: konghq.com/plugins: skyflow-deidentify
```

### Konnect

Same `config` block via the Konnect control-plane API/UI; inject credentials as
control-plane secrets and let data planes resolve the `{vault://…}` references.

## 8.3 Observability

### Metrics (emitted in the `log` phase; Prometheus/StatsD friendly)

| Metric | Type | Labels | Meaning |
| ------ | ---- | ------ | ------- |
| `skyflow_requests_total` | counter | `phase`, `result` | de-identify/re-identify attempts by outcome |
| `skyflow_entities_detected_total` | counter | `entity` | count of detected entities by type (no values) |
| `skyflow_latency_ms` | histogram | `phase` | Skyflow round-trip latency |
| `skyflow_errors_total` | counter | `phase`, `class` | timeout/5xx/401/403/429/parse |
| `skyflow_posture_total` | counter | `posture` | deny/allow/skip taken |
| `skyflow_token_cache` | counter | `event` | hit/miss/refresh/mint |
| `skyflow_spans` | histogram | `phase` | spans processed per request |

### Logs

Structured JSON via `kong.log`: request id, route/service/consumer ids, profile,
spans, `entities_by_type` counts, Skyflow latency, error class, posture,
`dry_run`. **Never** values. Tunable via `log.sample_rate`.

### Alerts (suggested)

- `skyflow_errors_total` rate > threshold → Skyflow degradation.
- `skyflow_posture_total{posture="allow"} > 0` → **fail-open occurred** (privacy
  signal) — page if `on_skyflow_error=allow` is unexpected.
- token `mint` rate spikes → cache/single-flight regression.
- p95 `skyflow_latency_ms` breach → upstream/network issue.

## 8.4 Latency budget

Added latency ≈ Skyflow round-trips (auth is amortized to ≈0 via cache):

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

## 8.5 Rollout playbook

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

## 8.6 Capacity & limits

- Memory: bounded by `max_body_size` × in-flight requests; size workers
  accordingly for large prompts.
- The bearer-token cache is node-wide; expect a single mint per node per token
  lifetime under single-flight.
- For very large corpora or file modalities, prefer an async pipeline over the
  synchronous proxy path (out of scope for v1; see [`docs/01`](01-overview.md#14-non-goals)).

## 8.7 Troubleshooting

| Symptom | Likely cause | Action |
| ------- | ------------ | ------ |
| 502 with `skyflow_errors_total{class="timeout"}` | Skyflow unreachable/slow | check egress/DNS/TLS to cluster; raise `timeout_ms`/`deadline_ms`; verify region. |
| 403 from Skyflow | SA role lacks Detect permission | grant "De-identify and reidentify…"; for detokenize, add read/detokenize. |
| Upstream still sees PII | plugin after AI Proxy, or wrong profile/paths | set dynamic `ordering.before.access`; verify `profile`/`request_json_paths`. |
| Re-identify not happening | `reidentify.enabled=false`, streamed + `passthrough`, or `mapping_only` missing tokens | enable; use `buffer`; check token source. |
| Credentials visible concern | — | they're `encrypted`+`referenceable`; confirm via `GET /plugins` returns no raw secret. |
| High latency | cold token cache / no keepalive / serial batching | confirm cache hits; raise `keepalive_pool_size`; use `per_span` concurrency or `mapping_only`. |
