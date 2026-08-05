# Architecture

## 2.1 Where the plugin sits

Kong injects custom logic at well-defined points in the request lifecycle. This
plugin is an **HTTP-module** plugin that acts in two phases:

- **`access`** — runs for every request before it is proxied upstream. This is
  where we read the client request body, call Skyflow **De-identify**, and
  rewrite the outbound body so the upstream only ever receives tokenized content.
- **`response`** — runs after the full upstream response is received but before
  any byte is sent to the client (this implicitly enables Kong's **buffered
  proxy** mode). This is where we call Skyflow **Re-identify** and rewrite the
  response body. Only active when `reidentify.enabled = true`.

> **Composing with AI Proxy.** The plugin does **not** share a route with
> `ai-proxy`. `ai-proxy` transforms the LLM response in its `header_filter`,
> while our re-identify must run in the `response` phase (it calls Skyflow over a
> cosocket, banned in `body_filter`); on one route the two fight over the
> buffered body and `ai-proxy` 500s with "no response body found when
> transforming response" whenever the upstream body is gzip-encoded (real OpenAI
> always is — [Kong #14380](https://github.com/Kong/kong/issues/14380)). Instead
> they run on **two routes** — see the nested-proxy topology in [§2.8](#28-deployment-topologies).

We also use:

- **`init_worker`** — one-time per-worker setup (HTTP connection pool warm-up,
  metrics registration).
- **`configure`** — react to config changes (validate reachability, pre-warm an
  auth token).
- **`log`** — emit metrics/structured logs (counts, latencies, error classes) —
  never the de-identified values themselves.

```
            ┌───────────────────────── Kong worker (OpenResty) ─────────────────────────┐
 client ───▶│ rewrite │ ACCESS* │ ───────▶ upstream ───────▶ │ RESPONSE* │ │ log │ ─────▶ client
            └─────────────┼───────────────────────────────────────┼──────────────┼──────┘
                          │ de-identify                            │ re-identify  │ metrics
                          ▼                                        ▼              ▼
                   Skyflow Detect                            Skyflow Detect    (no PII)
                   /deidentify                               /reidentify
                                                             or /detokenize
   * skyflow-ai-data-control phases
```

## 2.2 Module decomposition

```
kong.plugins.skyflow-ai-data-control
├── handler.lua   Orchestration. Implements the lifecycle phases above. Holds no
│                 business logic beyond sequencing and PDK I/O.
├── schema.lua    Declarative configuration contract (validated by Kong core).
├── auth.lua      Skyflow credential → bearer token. Supports api_key, static
│                 token, and service-account JWT (RS256). Caches the token with
│                 TTL via kong.cache; refreshes before expiry; single-flight.
├── client.lua    Thin Skyflow Detect REST client over lua-resty-http with a
│                 keepalive pool. One function per operation:
│                 deidentify_text(), reidentify_text(), detokenize().
│                 Handles timeouts, retries (idempotent ops), and error mapping.
├── body.lua      Payload model. Detects the wire format (openai/anthropic/mcp)
│                 from the body shape, then -- with any JSONPath additions merged
│                 in -- extracts the list of "text spans" to de-identify and
│                 writes processed text back into the same spans.
└── mapping.lua   Request-scoped store of {token → original_value, entity} built
                  during access, consumed during response. Lives only in
                  kong.ctx.plugin for the life of one request.
```

### Separation of concerns

- `handler.lua` knows **Kong** (PDK), not Skyflow wire format.
- `client.lua`/`auth.lua` know **Skyflow**, not Kong request shape.
- `body.lua` knows **payload shape**, not Skyflow or Kong I/O.
- This keeps each unit independently unit-testable (see [`testing`](testing.md)).

## 2.3 Request path (de-identify) — sequence

```
Client          Kong (access)            body.lua        auth.lua        client.lua      Skyflow Detect
  │  request       │                         │              │               │                 │
  ├───────────────▶│                         │              │               │                 │
  │                │ get_raw_body()          │              │               │                 │
  │                ├────────────────────────▶│ parse + select spans         │                 │
  │                │   spans[] (text only)   │              │               │                 │
  │                │◀────────────────────────┤              │               │                 │
  │                │ ensure token            │              │               │                 │
  │                ├──────────────────────────────────────▶│ cached? else mint & cache        │
  │                │                          bearer token  │◀──────────────┤                 │
  │                │ deidentify(spans, cfg)   │              │               │                 │
  │                ├──────────────────────────────────────────────────────▶│ POST /deidentify│
  │                │                                                        ├────────────────▶│
  │                │                                                        │  processed_text,│
  │                │                                                        │  entities[]     │
  │                │                                                        │◀────────────────┤
  │                │  processed spans + entity map                          │                 │
  │                │◀───────────────────────────────────────────────────────┤                 │
  │                │ write spans back into body (body.lua)                   │                 │
  │                │ kong.service.request.set_raw_body(newBody)             │                 │
  │                │ stash {token→value} in kong.ctx.plugin (mapping.lua)   │                 │
  │                │ if reidentify: enable_buffering()                      │                 │
  │                │────────── proxied upstream (tokens only) ─────────────────────────────▶ │
```

**Batching.** All text spans for a request are de-identified in **one** Detect
call where possible (the Detect API processes a text payload at a time; multiple
chat messages are joined with unambiguous separators or sent as repeated calls
per the chosen batching strategy — see [`skyflow-integration §3.4`](skyflow-integration.md#34-batching-multiple-spans)).
This bounds the added latency to a single round-trip regardless of message count.

## 2.4 Response path (re-identify) — sequence

```
Skyflow Detect     client.lua      Kong (response)        body.lua         Client
   │                   │                 │                    │              │
   │  upstream resp buffered by Kong     │                    │              │
   │                   │  get upstream body (service.response.get_raw_body)  │
   │                   │                 ├───────────────────▶│ select spans │
   │                   │                 │   spans[]          │              │
   │ POST /reidentify  │◀────────────────┤ (text + entity hints from mapping)│
   │◀──────────────────┤                 │                    │              │
   │ processed_text    │                 │                    │              │
   ├──────────────────▶│ restored spans  │                    │              │
   │                   ├────────────────▶│ write back (body.lua)             │
   │                   │                 │ kong.response.set_raw_body(new)   │
   │                   │                 ├──────────────────────────────────▶│ (real values)
```

Re-identify uses the **mapping** captured during `access` to know which tokens
to restore and as which entity class (`redacted`/`masked`/`plain_text`). When
`VAULT_TOKEN` format is used and the payload is structured, the plugin can
instead call vault **detokenize** per token. See
[`skyflow-integration §3.5`](skyflow-integration.md#35-re-hydration-strategies).

## 2.5 Streaming considerations

LLM responses are frequently **streamed** (SSE / chunked) when the client sends
`stream: true`. Re-identification needs the *whole* relevant text to map tokens
reliably, and tokens may straddle chunk boundaries. Three modes, configurable
via `reidentify.streaming`:

| Mode | Behavior | Trade-off |
| ---- | -------- | --------- |
| `buffer` (default when reidentify on) | Force buffered proxy; re-identify the complete body once; emit non-streamed. | Loses incremental streaming UX; correct + simple. Incompatible with HTTP/2 & gRPC upstreams (Kong buffered-proxy limitation). |
| `passthrough` | Do **not** re-identify streamed responses; only buffer & re-identify non-streamed ones. | Streams stay fast; streamed responses contain tokens (acceptable if the model rarely echoes PII tokens). |
| `reassemble` (advanced/experimental) | `body_filter` accumulates SSE deltas, re-identifies on safe boundaries, re-emits as a stream. | Best UX; complex; must handle partial-token buffering and flush-on-finish. |

> **De-identify is unaffected by streaming**: request bodies are sent whole by
> the client, so `access` always has the full body.

When `reidentify.enabled = false` (de-identify only — the most common posture),
**no buffering is imposed** and streaming works normally.

## 2.6 Caching model

| Cached item | Where | TTL / scope | Why |
| ----------- | ----- | ----------- | --- |
| Skyflow **bearer token** | `kong.cache` (mlcache over the shared dict; node-wide, multi-worker) | `expiry − skew` (≈55 min for 60-min tokens) | Avoid re-minting on every request; single-flight refresh under `lua-resty-lock`. |
| HTTP **keepalive** to Skyflow | `lua-resty-http` connection pool per worker | pool idle timeout | Amortize TLS handshake; bounded pool size. |
| **Token↔value mapping** | `kong.ctx.plugin` (request-scoped, in-memory) | one request | Needed to re-identify the matching response. **Never** shared or persisted. |
| Detect **results** | *not cached* | — | Per-request data; caching plaintext would be a leak (see [`security`](../using/security.md)). |

## 2.7 Failure modes & posture

| Failure | Behavior (`operations.on_error.skyflow`) | Notes |
| ------- | ----------------------------- | ----- |
| Skyflow timeout / 5xx on **de-identify** | `deny` (default): `kong.response.exit(502, ...)`; `allow`: forward original body | Default never leaks raw PII. Emits metric `skyflow_deidentify_error`. |
| Skyflow auth failure (401/403) | Always `deny` + log; attempt one token refresh+retry first | A bad credential must not silently fall through. |
| Body not parseable as JSON | `skip` (forward unchanged) or `deny`, per `operations.on_error.parse` | A non-JSON body on a route configured for JSON is a misconfiguration signal. |
| Body parses but the wire format is unrecognised | `deny` (500) unless `request_json_paths` is set | Scanning nothing while reporting success is the one failure this plugin must never have. |
| Skyflow error on **re-identify** | Return the **tokenized** response (never 5xx the user over re-ID), log, metric | The upstream succeeded; degrade to tokens rather than failing the call. Configurable via `reidentify.on_error`. |
| Request body exceeds `max_body_size` | `deny` or `skip` per config | Avoid unbounded memory; large bodies handled per [`operations`](../using/operations.md). |
| Plugin internal error | `pcall`-guarded; same posture as `operations.on_error.skyflow` | Never crash the worker; structured error log. |

## 2.8 Deployment topologies

### T1 — Nested proxy with AI Proxy (recommended for LLMs)

```
client → [ /ai/chat: skyflow-ai-data-control (access: de-id) ]
             → (loopback) → [ /_ai_upstream: ai-proxy ] → provider
client ← [ /ai/chat: skyflow-ai-data-control (response: re-id) ]
             ← (loopback) ← [ /_ai_upstream: ai-proxy ] ← provider
```

`ai-proxy` and the response-phase re-identifier **cannot share a route**
(Kong [#14380](https://github.com/Kong/kong/issues/14380): `ai-proxy` reads the
buffered response in its `header_filter`, which collides with our `response`-phase
rewrite of the gzip body → `500 "no response body found"`). So they run on two
routes: a **front route** does de-id + re-id and proxies (loopback to Kong's own
port) to an **internal route** that runs `ai-proxy` alone. Two independent
buffered cycles, no collision. Ready-to-run in
[`deploy/streaming/kong.yaml`](../../deploy/streaming/kong.yaml);
reproduced + verified offline in [`test/offline-harness/`](../../test/offline-harness).

### T2 — Standalone proxy to any upstream (MCP / generic)

```
client → [ skyflow-ai-data-control ] → Kong Service/Route → upstream (MCP server, REST API)
```

No AI Proxy; the plugin is the only AI/privacy plugin on the Route.

### T3 — Egress gateway

Kong deployed as a forward/egress proxy so *all* outbound AI traffic from a VPC
passes the plugin globally (plugin scoped **global** or per-Service). Pairs with
IP allowlists and mTLS to providers.

### T4 — Konnect / hybrid

Control plane in Konnect, data planes self-hosted near the workloads. Plugin
config is declarative and distributed by Konnect; Skyflow credentials injected
to data planes via env/secret references (see [`security`](../using/security.md)).

## 2.9 Concurrency & performance shape

- **Added latency** ≈ auth (amortized to ~0 via cache) + **1** Detect round-trip
  on the request, and (if enabled) **1** Re-identify round-trip on the response.
  Budget and tuning in [`operations §8.4`](../using/operations.md#latency-budget).
- All Skyflow I/O uses OpenResty's non-blocking cosockets — a worker handles
  other requests while awaiting Skyflow.
- No blocking calls, no `os.time`-based sleeps in the hot path; token refresh is
  single-flight so a burst doesn't trigger a thundering herd of token mints.

## 2.10 Data-flow trust boundaries

```
        TRUST BOUNDARY (your infra)                    │  EXTERNAL
 ┌───────────────────────────────────────────┐        │
 │ client → Kong (plaintext in memory only)   │        │
 │            │                                │        │
 │            ├── TLS ──▶ Skyflow Vault (PII leaves only to the vault, governed)
 │            │                                │        │
 │            └── tokens ───────────────────────────────┼──▶ LLM / MCP / API (never sees raw PII)
 └───────────────────────────────────────────┘        │
```

The only parties that ever see raw values are the **client**, the **Kong worker
memory** (transiently), and the **Skyflow vault**. The upstream model/tool sees
only tokens. This is the core security property; it is restated and threat-
modeled in [`security`](../using/security.md).
