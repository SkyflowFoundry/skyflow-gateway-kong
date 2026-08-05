# Operations

Configuration recipes, observability, performance budgets, and rollout guidance.

## Installation

```bash
# Into a Kong node / image
luarocks install skyflow-ai-data-control        # or: luarocks make ./*.rockspec

# Tell Kong to load it
export KONG_PLUGINS=bundled,skyflow-ai-data-control
# (or kong.conf: plugins = bundled,skyflow-ai-data-control)

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
      - name: skyflow-ai-data-control
        config:
          skyflow:
            vault_configuration:
              vault_id: "${SKYFLOW_VAULT_ID}"
              vault_url: "${SKYFLOW_VAULT_URL}"      # https://<cluster>.vault.skyflowapis.com
            credentials:
              method: sts
              sts:
                service_account_id: "{vault://env/SKYFLOW_SERVICE_ACCOUNT_ID}"
            deidentify:
              entities: [NAME, SSN, CREDIT_CARD, EMAIL_ADDRESS, PHONE_NUMBER]
              token_format: VAULT_TOKEN
          operations:
            on_error: { skyflow: deny }
```

### decK (de-identify + re-identify, composed with AI Proxy — nested proxy)

`skyflow-ai-data-control` and `ai-proxy` **cannot share a route** (Kong #14380 — see
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
      - name: skyflow-ai-data-control
        config:
          skyflow:
            vault_configuration:
              vault_id: "${SKYFLOW_VAULT_ID}"
              vault_url: "${SKYFLOW_VAULT_URL}"
            credentials:
              sts: { service_account_id: "{vault://env/SKYFLOW_SERVICE_ACCOUNT_ID}" }
            deidentify: { entities: [NAME, EMAIL_ADDRESS, PHONE_NUMBER], token_format: VAULT_TOKEN }
            # reidentify defaults to enabled + reidentify_text, so it needs no block.
          operations:
            on_error: { skyflow: deny }
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
[`deploy/streaming/kong.yaml`](../../deploy/streaming/kong.yaml).

### Admin API

```bash
curl -X POST http://localhost:8001/routes/chat/plugins \
  --data name=skyflow-ai-data-control \
  --data config.skyflow.vault_configuration.vault_id=$SKYFLOW_VAULT_ID \
  --data config.skyflow.vault_configuration.vault_url=$SKYFLOW_VAULT_URL \
  --data config.skyflow.credentials.sts.service_account_id=$SKYFLOW_STS_SERVICE_ACCOUNT_ID \
  --data 'config.skyflow.deidentify.entities=NAME,EMAIL_ADDRESS'
```

### Kubernetes (KIC)

```yaml
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata: { name: skyflow-ai-data-control, namespace: ai }
plugin: skyflow-ai-data-control
config:
  skyflow:
    vault_configuration:
      vault_id: { valueFrom: { secretKeyRef: { name: skyflow, key: vault_id } } }
      vault_url: { valueFrom: { secretKeyRef: { name: skyflow, key: vault_url } } }
    credentials:
      sts: { service_account_id: "{vault://k8s/skyflow/service-account-id}" }
    deidentify: { entities: [NAME, EMAIL_ADDRESS], token_format: VAULT_TOKEN }
# annotate the Ingress/HTTPRoute/Service: konghq.com/plugins: skyflow-ai-data-control
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
- Any `skyflow.posture = allow` when you run `operations.on_error.skyflow = deny` → a
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

- Spans run in concurrent waves of 8, so a multi-message prompt costs roughly
  `ceil(spans / 8)` round trips rather than one per span. Fixed, not tunable.
- `mapping_only` to avoid the second Skyflow call entirely when applicable.
- connections to Skyflow are pooled per worker, so TLS handshakes are not per-request.
- co-locate data planes near the Skyflow cluster region.
- The whole-request deadline (60 s) bounds the worst case. Re-identify failures
  return the tokenized response rather than failing the call — fixed behaviour,
  not a setting.

Because Skyflow I/O is non-blocking (cosockets), added latency does **not**
proportionally reduce worker throughput.

## Rollout playbook

1. **Observe (`dry_run=true`):** enable on a Route; the plugin detects and logs
   entity counts but does **not** alter traffic. Validate detection coverage and
   latency.
2. **Enforce de-identify** (`operations.dry_run=false`,
   `skyflow.reidentify.enabled=false`): start tokenizing outbound traffic with
   `operations.on_error.skyflow=deny`. Watch error and posture metrics.
3. **Enable re-identify** for the responses that need it — the default — and
   validate the UX. Responses are buffered while this is on, which is what makes
   a token split across SSE chunks resolvable.
4. **Tune:** adjust entities and `limits.max_spans`; consider
   `mapping_only` for latency-sensitive routes that never need to resolve a token
   from an earlier turn.
5. **Scale out:** roll to more Routes/Services or go global on an egress gateway.

Rollback is a config flip (`dry_run=true` or disable the plugin) — no data
migration, no schema/DAO state.

## Capacity & limits

- Memory: bounded by `max_body_size` × in-flight requests; size workers
  accordingly for large prompts.
- HTTP connections to Skyflow are pooled per worker (16 per pool) to
  avoid a TLS handshake on every call.
- For very large corpora or file modalities, prefer an async pipeline over the
  synchronous proxy path (not supported today; see [overview](overview.md#non-goals)).

## Troubleshooting

| Symptom | Likely cause | Action |
| ------- | ------------ | ------ |
| 502 on de-identify | Skyflow unreachable/slow (fail-closed) | check egress/DNS/TLS to the vault URL; verify the region. Timeouts are fixed at 15 s per attempt / 60 s per request. |
| 403 from Skyflow | the API key's role lacks the Detect permission | grant Detect de-identify (and reidentify, if you re-identify). |
| Upstream still sees PII | de-identify not on the request path, or an unrecognised body shape | with `ai-proxy`, use the nested-proxy layout (de-identify on the front route; see the nested-proxy example above). If the log says `unrecognised request wire format`, set `request_json_paths` for that route. |
| Re-identify not happening | `reidentify.enabled=false`, streamed + `passthrough`, or `mapping_only` missing tokens | enable it; use `buffer`; check the token source. |
| Credential visible concern | — | credentials are `encrypted`+`referenceable`; confirm `GET /plugins` returns no raw secret. |
| High latency | many spans per request | check the span count in the logs; lower `limits.max_spans` or narrow `deidentify.entities`; consider `mapping_only`; co-locate the data plane near the vault region. |
