# Plugin Specification

Defines the plugin's identity, module layout, configuration schema, lifecycle
handlers, and PDK usage. The reference skeleton in
[`plugin/kong/plugins/skyflow-ai-data-control/`](../../plugin/kong/plugins/skyflow-ai-data-control)
implements this spec.

## 4.1 Identity

| Attribute | Value |
| --------- | ----- |
| Plugin name | `skyflow-ai-data-control` |
| Lua namespace | `kong.plugins.skyflow-ai-data-control.*` |
| Priority (default) | `775` — de-identify runs in `access`; below AI PII Sanitizer (776). Composes with `ai-proxy` via **nested routes**, not shared-route priority (see [`architecture §2.8`](architecture.md#28-deployment-topologies)) |
| Phases implemented | `access`, `response`, `log` (the design also allows `init_worker`/`configure`; the Konnect single-file build omits them) |
| Protocols | `http`, `https`, `grpc`, `grpcs`, `ws`, `wss` |
| Scopes | global, Service, Route, Consumer, Consumer Group |
| DB / DAOs | none (no custom entities, no migrations) |
| External deps | `lua-resty-http`, `cjson` (runtime-provided). **No** `lua-resty-jwt` — API-key/static-token auth; service-account JWT (RS256 via `resty.openssl`) is a follow-up |

> **Packaging:** the shipped build targets **Konnect Dedicated Cloud Gateways**,
> which require two self-contained files. The module layout in §4.2 is the
> *logical* design; physically, `auth`/`client`/`body`/`mapping` are inlined
> into `handler.lua`, and `schema.lua` is `require`-free. See
> [`deployment`](../using/deployment.md).
>
> **Why `response` not `header_filter`+`body_filter`:** Kong forbids a plugin
> from implementing `response` *and* `header_filter`/`body_filter`. We use
> `response` (which wraps both and auto-enables buffered proxy) for the
> buffered re-identify path, and reserve a separate **build-time flag** for the
> experimental `body_filter` streaming reassembler (mutually exclusive config).

## 4.2 Module layout

```
kong/plugins/skyflow-ai-data-control/
  handler.lua    -- PDK lifecycle orchestration (this doc §4.4)
  schema.lua     -- configuration contract (this doc §4.3)
  auth.lua       -- bearer-token manager (skyflow-integration §3.2)
  client.lua     -- Detect REST client (skyflow-integration §3.3–3.5, §3.8)
  body.lua       -- payload profiles + span extract/replace (this doc §4.5)
  mapping.lua    -- request-scoped token map (skyflow-integration §3.6)
  *.rockspec     -- packaging (development)
```

## 4.3 Configuration schema (`schema.lua`)

Top-level config object. Types use Kong's typedefs where possible.

### 4.3.1 Connection & auth

| Field | Type | Default | Req | Description |
| ----- | ---- | ------- | --- | ----------- |
| `vault_id` | string | — | ✅ | Skyflow vault ID. |
| `cluster_id` | string | — | ✅ | Vault cluster (first segment of vault URL). |
| `account_id` | string | — | | Sent as `X-SKYFLOW-ACCOUNT-ID` when present. |
| `env` | string (enum) | `PROD` | | `PROD`\|`SANDBOX`\|`DEV`\|`STAGE`. |
| `skyflow_base_url_override` | string | — | | Full base URL for private-cloud tenants (bypasses derivation). |
| `credentials.token` | string (referenceable, encrypted) | — | one-of | Static bearer token. |
| `credentials.role_ids` | array<string> | — | | Scoped-token roles (SA-JWT only). |
| `credentials.context` | map<string,string> | — | | Policy context embedded in SA-JWT (`ctx`). |
| `token_skew_seconds` | integer | `300` | | Refresh the cached token this long before `expiresIn`. |

`credentials` is an exactly-one-of: `api_key` \| `token` \| `service_account_json`.
All three are **referenceable** (`{vault://…}`) and marked **encrypted** so they
are never stored in plaintext in the DB and never appear in `GET /plugins`.

### 4.3.2 Payload targeting

| Field | Type | Default | Description |
| ----- | ---- | ------- | ----------- |
| `profile` | string (enum) | `openai` | `openai`\|`anthropic`\|`mcp`\|`generic`. Built-in span selectors (§4.5). |
| `request_json_paths` | array<string> | profile default | JSONPaths whose **string** values are de-identified. Overrides/extends the profile. |
| `response_json_paths` | array<string> | profile default | JSONPaths re-identified on the response. |
| `content_type` | string (enum) | `auto` | `auto`\|`json`\|`text`. `auto` sniffs `Content-Type`. |
| `max_body_size` | integer (bytes) | `1048576` | Bodies larger than this hit `on_parse_error`. |
| `max_spans` | integer | `64` | Cap on text spans per request. |

### 4.3.3 De-identify behavior

| Field | Type | Default | Description |
| ----- | ---- | ------- | ----------- |
| `deidentify.entities` | array<string> | `[]` | Entity types to detect; `[]` ⇒ Skyflow defaults. |
| `deidentify.token_format` | string (enum) | `VAULT_TOKEN` | `VAULT_TOKEN`\|`ENTITY_ONLY`\|`ENTITY_UNQ_COUNTER`. |
| `deidentify.allow_regex` | array<string> | `[]` | Patterns to **never** tokenize. |
| `deidentify.restrict_regex` | array<string> | `[]` | Extra patterns to **always** tokenize. |
| `deidentify.shift_dates` | record | — | `{ enabled, min_days, max_days, entities[] }`. |
| `deidentify.batch_mode` | string (enum) | `per_span` | `per_span`\|`joined` (skyflow-integration §3.4). |

### 4.3.4 Re-identify behavior

| Field | Type | Default | Description |
| ----- | ---- | ------- | ----------- |
| `reidentify.enabled` | boolean | `false` | Master switch for response re-hydration. |
| `reidentify.strategy` | string (enum) | `reidentify_text` | `reidentify_text`\|`detokenize`\|`mapping_only` (skyflow-integration §3.5). |
| `reidentify.entity_treatment` | map<string,string> | `{}` | Per-entity: `plain_text`\|`masked`\|`redacted`. Unlisted ⇒ `default_treatment`. |
| `reidentify.default_treatment` | string (enum) | `plain_text` | Treatment for entities not in the map. |
| `reidentify.streaming` | string (enum) | `buffer` | `buffer`\|`passthrough`\|`reassemble` (architecture §2.5). |
| `reidentify.on_error` | string (enum) | `return_tokenized` | `return_tokenized`\|`deny`. |

### 4.3.5 Resilience & limits

| Field | Type | Default | Description |
| ----- | ---- | ------- | ----------- |
| `timeout_ms` | integer | `5000` | Per-attempt connect/send/read timeout to Skyflow. |
| `deadline_ms` | integer | `8000` | Total budget incl. retries. |
| `retries` | integer | `2` | Max retries for idempotent/ retryable Skyflow errors. |
| `max_concurrency` | integer | `8` | Parallel Detect calls for `per_span` batching. Wired into the concurrent span runner (`run_waves`), which issues waves of this width. Must stay `<= keepalive_pool_size` or waves contend for connections. |
| `keepalive_pool_size` | integer | `16` | `lua-resty-http` pool size per worker. |
| `keepalive_idle_ms` | integer | `60000` | Keepalive idle timeout. |
| `on_skyflow_error` | string (enum) | `deny` | `deny`\|`allow` (de-identify failure posture). |
| `on_parse_error` | string (enum) | `deny` | `deny`\|`skip`. |
| `dry_run` | boolean | `false` | Detect + map + log, but **don't** rewrite the body (rollout/observe mode). |

### 4.3.6 Observability

| Field | Type | Default | Description |
| ----- | ---- | ------- | ----------- |
| `log.detections` | boolean | `true` | Emit per-request entity **counts** (never values). |
| `log.sample_rate` | number | `1.0` | Sampling for verbose logs. |
| `metrics.enabled` | boolean | `true` | Emit Prometheus/StatsD-compatible metrics via the log phase. |

### 4.3.7 Schema-level validation (entity checks)

- `credentials`: exactly one of `api_key` / `token` / `service_account_json`
  (`mutually_exclusive` + `at_least_one_of`).
- `reidentify.strategy = mapping_only` ⇒ require `deidentify.token_format ≠
  ENTITY_ONLY` (one-way tokens can't be reversed).
- `reidentify.streaming = reassemble` is gated behind a build flag and rejected
  unless explicitly enabled (experimental).
- `deadline_ms ≥ timeout_ms`.
- `profile = generic` ⇒ `request_json_paths` (or `content_type = text`) required.

## 4.4 Handler lifecycle (`handler.lua`)

```lua
local SkyflowDeidentify = { PRIORITY = 775, VERSION = "0.1.0" }
```

### `init_worker()`

- Initialize metrics counters/histograms.
- Nothing network-bound (workers start before config may be ready).

### `configure(configs)`

- Called whenever the plugin iterator rebuilds (3.4+). For each config:
  validate derived base URL, and **pre-warm** an auth token (best-effort, in a
  `ngx.timer` so startup isn't blocked). Surfaces credential/permission errors
  early in logs.

### `access(conf)`

1. Short-circuit if method/content-type indicates no body, or body > limits.
2. `body = kong.request.get_raw_body()` (+ buffered re-read if Kong spilled to
   disk; else `kong.request.get_body()` for parsed form).
3. `spans = body.extract(body, conf)` — list of `{path, text}`.
4. If no spans → return (nothing to do).
5. `token = auth.get(conf)` (cached).
6. `results = client.deidentify(spans, conf, token)` (batched per `batch_mode`,
   bounded concurrency, deadline-aware).
7. On error → `on_skyflow_error` posture (`deny` ⇒ `kong.response.exit(502)`).
8. `body.replace(spans → processed_text)` and
   `kong.service.request.set_raw_body(newBody)`; fix `Content-Length`.
9. `mapping.put(ctx, results.entities)`.
10. If `reidentify.enabled` and `streaming ≠ reassemble`:
    `kong.service.request.enable_buffering()`.
11. Record detection counts in `kong.ctx.plugin` for the `log` phase.

### `response(conf)` *(only when `reidentify.enabled`)*

1. Skip non-success or non-matching `Content-Type`.
2. `body = kong.service.response.get_raw_body()`.
3. `spans = body.extract_response(body, conf)`.
4. Re-identify per `strategy`:
   - `mapping_only` → substitute from `kong.ctx.plugin` map (no Skyflow call).
   - `reidentify_text` → `client.reidentify(spans, treatment, token)`.
   - `detokenize` → `client.detokenize(tokens, redaction, token)`.
5. On error → `reidentify.on_error` (`return_tokenized` ⇒ leave body as-is).
6. `body.replace` + `kong.response.set_raw_body(newBody)`; fix headers.

### `log(conf)`

- Emit structured log + metrics: `spans`, `entities_by_type` counts, Skyflow
  latencies, error class, posture taken, `dry_run` flag. **No values.**

All phase bodies are wrapped in `pcall`; an unexpected error degrades to the
configured posture and is logged, never crashing the worker.

## 4.5 Payload model (`body.lua`)

A **profile** maps a payload shape to the spans that carry user text.

| Profile | Request span selectors (defaults) | Response span selectors (defaults) |
| ------- | --------------------------------- | ---------------------------------- |
| `openai` | `$.messages[*].content` (string or `content[*].text` for array form), `$.input`, `$.prompt` | `$.choices[*].message.content`, `$.choices[*].text` |
| `anthropic` | `$.messages[*].content[*].text`, `$.system` | `$.content[*].text` |
| `mcp` | `$.params.arguments.*` (string leaves), `$.params.messages[*].content` | `$.result.content[*].text`, `$.result.*` (string leaves) |
| `generic` | `config.request_json_paths` (required) or whole body as text | `config.response_json_paths` or whole body |

Implementation notes:

- A small, dependency-free **JSONPath subset** (`$`, `.key`, `[*]`, `[n]`,
  recursive string-leaf selection) covers these needs; documented grammar in
  the module header. Avoids pulling a heavy JSONPath lib into the data plane.
- `extract` returns spans with their location so `replace` is exact and
  order-independent; non-string / empty leaves are skipped.
- For `content_type = text`, the whole body is one span.
- Malformed JSON under a JSON profile → `on_parse_error` posture.

## 4.6 PDK surface used

| PDK call | Phase | Purpose |
| -------- | ----- | ------- |
| `kong.request.get_raw_body()` / `get_body()` | access | read client body |
| `kong.service.request.set_raw_body()` / `set_header()` | access | rewrite outbound body & `Content-Length` |
| `kong.service.request.enable_buffering()` | access | allow reading full response body |
| `kong.service.response.get_raw_body()` / `get_status()` / `get_header()` | response | read upstream response |
| `kong.response.set_raw_body()` / `set_header()` / `exit()` | response/access | rewrite response / fail closed |
| `kong.ctx.plugin` | access→response/log | carry mapping + metrics |
| `kong.client.get_consumer()` | access | derive policy `ctx` for scoped tokens |
| `kong.cache` | all | cached bearer token (single-flight) |
| `kong.log.*` | all | structured logs |
| `resty.http`, `cjson.safe` | access/response | Skyflow I/O & (de)serialization |

## 4.7 Composition with AI Proxy

- **Ordering:** ship priority `775`, but for determinism document explicit
  dynamic ordering so de-identify always precedes the proxy:

  ```yaml
  plugins:
    - name: skyflow-ai-data-control
      config: { ... }
      ordering:
        before:
          access: [ai-proxy, ai-proxy-advanced]
  ```

- On the response, Kong runs `response`/body handlers in reverse, so
  re-identify naturally runs after AI Proxy has produced the body.
- The plugin is **transport-aware but provider-agnostic**: it edits the JSON
  body shape (via profile), and AI Proxy handles provider routing/auth/format.
