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
  body.lua       -- wire-format detection + span extract/replace (this doc §4.5)
  mapping.lua    -- request-scoped token map (skyflow-integration §3.6)
  *.rockspec     -- packaging (development)
```

## 4.3 Configuration schema (`schema.lua`)

Three top-level groups. Anything not listed here does not exist as a field —
several behaviours that were once configurable are now constants beside the code
that reads them, because each had one sensible value and every extra field is a
box someone has to reason about in the Konnect form.

Notably absent, and deliberately: **nothing selects the wire format.** OpenAI,
Anthropic and MCP are detected per request from the body shape (§4.5).

### 4.3.1 `skyflow.vault_configuration`

Mirrors the vault's own page in the Skyflow admin UI, under the same names.

| Field | Type | Default | Req | Description |
| ----- | ---- | ------- | --- | ----------- |
| `vault_id` | string | — | ✅ | Vault that stores tokens and resolves re-identification. |
| `vault_url` | string | — | ✅ | The URL as the UI shows it, e.g. `https://ebfc9bee4242.vault.skyflowapis.com`. Taken whole rather than assembled from a cluster id, because the host also encodes the environment — a sandbox vault is on `.skyflowapis.tech`. Tolerates a trailing slash and a missing scheme. Also the hook the offline harness uses to point at a mock. |
| `account_id` | string | — | | Sent as `X-SKYFLOW-ACCOUNT-ID` when set. |

### 4.3.2 `skyflow.credentials`

`method` selects which record is read, with **no fallback**: under `sts`, a
populated `bearer_token` is never touched.

| Field | Type | Default | Description |
| ----- | ---- | ------- | ----------- |
| `method` | string (enum) | `sts` | `sts`\|`jwt_credential`\|`bearer_token`. |
| `sts.service_account_id` | string | — | Required when `method = sts`. |
| `sts.token_header` | string | `authorization` | Header carrying the caller's IdP token. |
| `sts.token_uri` | string | Skyflow STS | Exchange endpoint. |
| `sts.expected_issuer` / `sts.expected_audience` | string | — | Checked locally before any network hop, so an unauthenticated request costs nothing. |
| `jwt_credential.service_account_json` | string (referenceable, encrypted) | — | The whole service-account JSON. |
| `bearer_token.api_key` | string (referenceable, encrypted) | — | A Skyflow bearer, used as-is. |

Under `sts` the gateway holds **no** Skyflow credential at all: it exchanges the
caller's IdP token per request (RFC 8693), so compromising the gateway yields no
vault access.

### 4.3.3 `skyflow.deidentify`

| Field | Type | Default | Description |
| ----- | ---- | ------- | ----------- |
| `entities` | array<string> | `[]` | Validated against the types the vault has columns for, so a typo is refused at save time rather than silently matching nothing. `[]` ⇒ ALL. |
| `token_format` | string (enum) | `VAULT_TOKEN` | `VAULT_TOKEN`\|`ENTITY_ONLY`\|`ENTITY_UNQ_COUNTER`. Re-identification requires `VAULT_TOKEN`. |
| `configuration_source` | string (enum) | `inline` | `inline`\|`config_id`. See below. |
| `config_id` | string | — | Required when `configuration_source = config_id`. |
| `destination_table` | string | `table1` | Table holding the entity columns. |
| `allow_regex` | array<string> | `[]` | Sent as `skip`: suppresses false **positives**, leaving matches as plaintext. |
| `restrict_regex` | array<string> | `[]` | Sent as `restrict`: catches false **negatives**, turning matches into `[RESTRICTED]` whether or not a detector fired. |
| `token_preamble.enabled` / `.text` | boolean / string | `true` / built-in | Prepended to the outbound system prompt. Not part of the Detect call, so it applies under either `configuration_source`. |

**`configuration_source` is a selector, not a merge.** Detect models the two as a
protobuf `oneof` named `configurationSource` and rejects a request that sets both.
Under `config_id`, a saved configuration owns every detection decision, so
`entities`, `token_format`, `destination_table` and both regex lists are ignored.

**Destinations are derived, not configured.** Every entity tokenized as
`VAULT_TOKEN` needs a `destination` — the vault `table.column` storing it. The
Detect vault schema is mechanical (`NAME` → `table1.name_entity` across every
column), so only the table name is a field. Asking for 70 mappings by hand would
restate a rule the schema already follows.

### 4.3.4 `skyflow.reidentify`

| Field | Type | Default | Description |
| ----- | ---- | ------- | ----------- |
| `enabled` | boolean | `true` | Off means the **client** also receives tokens — a valid posture, but a surprising default. |
| `strategy` | string (enum) | `reidentify_text` | `reidentify_text` resolves through the vault, so it restores tokens minted on an earlier turn; `mapping_only` uses the request-scoped map and cannot. |
| `tool_inputs` | string (enum) | `tokenized` | Tool arguments the model sends back. An unknown tool is assumed to ship them somewhere the gateway does not control. |
| `tool_inputs_by_tool` | map<string,string> | `{}` | Per-tool override: exact name or a `*`-suffixed prefix (exact beats prefix, longest prefix wins). Tools running on the caller's **own machine** need `plain_text` — an `Edit` call whose `old_string` is a vault token writes that token into the user's real file. |

Fixed rather than configurable: re-identify failures return the tokenized
response (the upstream call already succeeded, so 502-ing throws away a paid-for
answer), the response is buffered (a token split across SSE chunks cannot be
matched), and per-entity masking is not offered — it only ever applied under
`mapping_only`, so with the default strategy it was config that did nothing.

### 4.3.5 `operations`

| Field | Type | Default | Description |
| ----- | ---- | ------- | ----------- |
| `limits.max_body_size` | integer (bytes) | `1048576` | Larger bodies hit `on_error.parse`. |
| `limits.max_spans` | integer | `64` | Over it the request is refused with **413** rather than partly de-identified. Agent traffic needs headroom: a short message can carry ~30 resent tool definitions. |

Transport and concurrency are **not configurable** — they are constants in
`handler.lua`, because they were derived from measurement rather than preference:

| Constant | Value | Why |
| -------- | ----- | --- |
| `TIMEOUT_MS` | `15000` | Per attempt. |
| `DEADLINE_MS` | `60000` | Whole request, across retries. Detect costs ~104 ms per span at the median and ~403 ms at p90, so a large agent request needs the full minute. |
| `RETRIES` | `2` | Idempotent operations only. |
| `MAX_CONCURRENCY` | `8` | Spans run in concurrent waves of this width, so a request costs `ceil(spans / 8)` round trips. |
| `KEEPALIVE_POOL_SIZE` | `16` | `lua-resty-http` pool per worker. |
| `KEEPALIVE_IDLE_MS` | `60000` | Pool idle timeout. |

Pinning `MAX_CONCURRENCY` and `KEEPALIVE_POOL_SIZE` together makes the invariant
between them true by construction: a wave wider than the pool contends for
sockets, and that can no longer be configured into existence.
| `on_error.skyflow` | string (enum) | `deny` | `deny`\|`allow`. |
| `on_error.parse` | string (enum) | `deny` | `deny`\|`skip`. |
| `dry_run` | boolean | `false` | Detect and log, forward the body unchanged — for measuring what a route carries before enforcing. |
| `log.detections` | boolean | `true` | Entity **counts** by type. Never values. |
| `log.sample_rate` | number | `1.0` | Sampling for verbose logs. |
| `metrics.enabled` | boolean | `true` | Emitted from the log phase. |

Every limit is a **fail-closed** bound rather than a hint: exceeding one refuses
the request instead of processing part of it.

### 4.3.6 Schema-level validation (entity checks)

- `credentials.method = sts` ⇒ `sts.service_account_id` required; likewise
  `jwt_credential.service_account_json` and `bearer_token.api_key` for their
  methods. Checks target the inner **fields**, not the records: Kong
  auto-materialises empty records, so a record-level check passes vacuously.
- `deidentify.configuration_source = config_id` ⇒ `config_id` required. Enforced
  here rather than left to the API, because an id that does not resolve reports
  `Field vault_id or configuration_id is missing in the request`, which names the
  wrong problem.
- `reidentify.strategy = mapping_only` ⇒ `deidentify.token_format ≠ ENTITY_ONLY`
  (one-way tokens cannot be reversed).
- `reidentify.strategy = reidentify_text` ⇒ `token_format = VAULT_TOKEN` (only
  vault tokens exist in the vault to resolve).

One rule lives in `handler.lua` instead, because the streamed-plugin upload
rejects a schema containing a custom validation function — and because the schema
could not express it anyway: an unrecognised wire format fails closed with a 422
once the body is parsed, and the body's shape is not knowable at config time.

## 4.4 Handler lifecycle (`handler.lua`)

```lua
local SkyflowAIDataControl = { PRIORITY = 775, VERSION = "0.7.0" }
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
6. `results = client.deidentify(spans, conf, token)` — spans run in concurrent
   waves of 8 (the `MAX_CONCURRENCY` constant), deadline-aware.
7. On error → `operations.on_error.skyflow` posture (`deny` ⇒ `kong.response.exit(502)`).
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

A **wire format** maps a payload shape to the spans that carry user text. The
format is **detected from the body**, not configured.

| Format | Request span selectors (defaults) | Response span selectors (defaults) |
| ------ | --------------------------------- | ---------------------------------- |
| `openai` | `$.messages[*].content` (string or `content[*].text` for array form), `$.input`, `$.prompt`, `$.user`, tool-call arguments | `$.choices[*].message.content`, `$.choices[*].text` |
| `anthropic` | `$.system` (+ `$.system[*].text`), `$.messages[*].content[*].text`, tool_result content, `$.metadata.user_id` | `$.content[*].text` |
| `mcp` | `$.params.arguments.*` (string leaves), `$.params.messages[*].content` | `$.result.content[*].text`, `$.result.*` (string leaves) |
| *(unrecognised)* | nothing — the request fails closed with a **422**. The supported shapes are the three above; anything else is a misrouted request, not a configuration gap. | — |

### Why the format is detected rather than configured

The OpenAI and Anthropic request shapes **overlap** at `$.messages[*].content`, so
a hand-set format is a silent failure waiting to happen: on an Anthropic body the
OpenAI selectors still match the user's typed message, so nothing errors and
nothing looks broken while the system prompt, every `tool_result` and the end-user
identifier go to the provider in clear text — 1 of 4 sensitive spans scanned on a
representative Claude Desktop request. Detection removes that failure mode
entirely. Discriminators, most to least specific:

1. `jsonrpc` / `method`+`params` ⇒ `mcp` (mandatory in the JSON-RPC spec).
2. Format-exclusive keys — `system`/`anthropic_version` ⇒ `anthropic`;
   `frequency_penalty`, `logit_bias`, `response_format`, `max_completion_tokens`,
   `input`, `prompt` ⇒ `openai`.
3. Content-block types — `tool_result`/`tool_use`/`image` ⇒ `anthropic`;
   `image_url`, or a `system`/`tool` **role** ⇒ `openai`.
4. Model-name namespace — `claude*` vs `gpt*`/`o<n>`/`text-`/`davinci`.
5. Still undecidable ⇒ **both**, and the two path sets are unioned. Over-scanning
   is free (a non-matching path yields no spans); under-scanning is a leak.

The one place ambiguity is *not* resolved by union is preamble injection, since an
OpenAI `role: "system"` message is **illegal** in the Anthropic API (hard 400)
while a top-level `system` string is valid Anthropic and merely ignored by OpenAI.
Ambiguity therefore takes the Anthropic shape: worst case is a preamble the model
never reads, not a request the provider refuses.

Implementation notes:

- A small, dependency-free **JSONPath subset** (`$`, `.key`, `[*]`, `[n]`,
  recursive string-leaf selection) covers these needs; documented grammar in
  the module header. Avoids pulling a heavy JSONPath lib into the data plane.
- `extract` returns spans with their location so `replace` is exact and
  order-independent; non-string / empty leaves are skipped.
- A body whose `Content-Type` is not JSON is treated as one whole-body span. JSON is assumed and sniffed from the header, not declared per route.
- Malformed JSON in JSON mode → `operations.on_error.parse` posture.

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
  body shape (via the detected wire format), and AI Proxy handles provider
  routing/auth/format.
