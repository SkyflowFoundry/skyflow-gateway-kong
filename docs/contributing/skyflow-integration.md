# Skyflow Detect Integration

This document specifies exactly how the plugin talks to Skyflow: authentication,
the De-identify / Re-identify / Detokenize operations, the request/response wire
shapes, the token↔value mapping model, batching, and error handling.

> **Source of truth.** Field names below are taken from Skyflow's published SDKs
> (`skyflow-python`, `skyflow-go`) and Detect API. Items marked **(confirm)** are
> tenant- or Detect-API-version-specific and must be validated against your
> Skyflow account before GA. The plugin isolates all of this in `client.lua` /
> `auth.lua`, so wire changes never touch the handler.

## 3.1 Endpoints & base URL

The base URL is `skyflow.vault_configuration.vault_url`, taken verbatim from the
vault's page in the admin console:

```
https://ebfc9bee4242.vault.skyflowapis.com
```

It is used whole rather than assembled from a cluster id, because the host also
encodes the environment — a sandbox vault is on `.skyflowapis.tech`, which no
amount of concatenating onto `.skyflowapis.com` would reach. A trailing slash and
a missing scheme are both tolerated. The same field is how the offline harness
points the client at a mock.

| Operation | Method & path | Used for |
| --------- | ------------- | -------- |
| De-identify text | `POST /v2/detect/deidentify/string` | Tokenize sensitive values in outbound request text |
| Re-identify text | `POST /v2/detect/reidentify/string` | Restore values into response text |
| De-identify file | `POST /v2/detect/deidentify/file` | Attachments; asynchronous, returns a `runId` |
| Poll a file run | `GET /v2/detect/runs/{runId}?vaultId=` | Await a terminal status for the above |
| Detokenize | `POST /v1/vaults/{vault_id}/detokenize` | Per-token re-hydration of structured fields (`VAULT_TOKEN`) |
| Identity exchange | `POST {token_uri}` (default `https://manage.skyflowapis.com/v1/auth/sts/token`) | Trade the caller's IdP token for a short-lived Skyflow bearer |

Two asymmetries in the wire contract worth knowing before reading the rest:

- De-identify carries the vault id **inside** `configuration.vaultId`; re-identify
  carries it at the **top level** as `vaultId`.
- The text endpoints are synchronous; the file endpoint is not, which is why
  attachments poll and text does not.

## 3.2 Authentication (`auth.lua`)

Three credential types, mirroring the Skyflow SDKs. The plugin selects whichever
is configured (see `config.credentials` in [`plugin-spec`](plugin-spec.md)).

### 3.2.1 API key (recommended for the PoC)

Simplest: no signing in the gateway.

```
Authorization: Bearer <SKYFLOW_API_KEY>
```

The key is sent directly; no token endpoint round-trip. Good for a PoC and for
low-ceremony deployments. Rotation is manual.

### 3.2.2 Service-account JWT (recommended for production)

`credentials.json` (issued in Skyflow Studio) contains `clientID`, `keyID`,
`tokenURI`, and an RSA `privateKey`. The plugin:

1. Builds a JWT and signs it **RS256** with `privateKey`:

   ```json
   {
     "iss": "<clientID>",
     "key": "<keyID>",
     "aud": "<tokenURI>",
     "sub": "<clientID>",
     "exp": <now + 3600>
   }
   ```

2. Exchanges it at `tokenURI`:

   ```http
   POST {tokenURI}
   Content-Type: application/json

   {
     "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
     "assertion": "<signed_jwt>"
   }
   ```

3. Receives `{ "accessToken": "...", "tokenType": "Bearer", "expiresIn": 3600 }`
   and uses `Authorization: Bearer <accessToken>` for Detect calls.

**Scoped tokens / context** (optional): include `role_ids` and/or a `ctx` value
so Skyflow policies can authorize per-caller (e.g. only certain consumers may
re-identify). The plugin can derive `ctx` from the authenticated Kong Consumer
(`kong.client.get_consumer()`), enabling per-consumer governance end-to-end.

### 3.2.3 Static bearer token

`credentials.token` — a pre-minted token. Useful only for short tests; expires
in ~60 min.

### 3.2.4 Token lifecycle

- Minted/refreshed lazily and cached in `kong.cache` keyed by a hash of the
  credential, re-minted 300 s before its own `exp`. A fixed margin rather than a
  config field: it guards against clock skew and in-flight latency, which is not
  something a deployment tunes.
- **Single-flight**: concurrent requests that find the token missing/expired
  coordinate via `lua-resty-lock` (mlcache does this) so only one mint happens.
- On a `401` mid-flight (token expired between check and use), the client does
  **one** forced refresh + retry, then surfaces the error.
- Required Skyflow role permission: **"De-identify and reidentify sensitive data
  in text and files."** Detokenize additionally needs record read/detokenize
  permission on the relevant column(s).

## 3.3 De-identify operation

### Request (`deidentify_text`)

```json
{
  "text": "Hi, I'm Jane Doe, SSN 123-45-6789, card 4111111111111111.",
  "configuration": {
    "vaultId": "<VAULT_ID>",
    "detect": {
      "entities": [
        { "entityType": "NAME",        "deidentificationType": "VAULT_TOKEN", "destination": "table1.name_entity" },
        { "entityType": "SSN",         "deidentificationType": "VAULT_TOKEN", "destination": "table1.ssn_entity" },
        { "entityType": "CREDIT_CARD", "deidentificationType": "VAULT_TOKEN", "destination": "table1.credit_card_entity" }
      ],
      "returnEntities": "ALL"
    }
  }
}
```

| Field | Maps from plugin config | Notes |
| ----- | ----------------------- | ----- |
| `text` | the extracted span | one call per span; spans run in concurrent waves of `operations.limits.max_concurrency` |
| `configuration.vaultId` | `skyflow.vault_configuration.vault_id` | omitted entirely under `configuration_source = config_id` |
| `detect.entities[].entityType` | `skyflow.deidentify.entities` | upper-cased; an empty list becomes a single `ALL` rule |
| `detect.entities[].deidentificationType` | `skyflow.deidentify.token_format` | per entity, not one global setting as in the older API |
| `detect.entities[].destination` | **derived** | `{destination_table}.{lower(entityType)}_entity`. Required whenever the type is `VAULT_TOKEN`; omitting it fails with `Missing Destination for entity NAME in DetectConfigV2`. It is a `table.column` reference, not an enum — `"VAULT"` is rejected with `invalid tableColumn format`. |
| `detect.skip` | `skyflow.deidentify.allow_regex` | suppresses false **positives**: matches are left as plaintext |
| `detect.restrict` | `skyflow.deidentify.restrict_regex` | catches false **negatives**: matches become `[RESTRICTED]` whether or not a detector fired |

The `ALL` rule pairs with `ENTITY_UNIQUE_COUNTER` rather than `VAULT_TOKEN`,
because "everything" has no single column to store into — the same reason the
attachment path escapes the destination requirement.

**Saved configurations.** `configurationId` and inline `configuration` are the two
arms of a protobuf `oneof` named `configurationSource`, so they are mutually
exclusive: sending both fails with `oneof … configurationSource is already set`.
Under `configuration_source = config_id` the body is just:

```json
{ "text": "…", "configurationId": "<CONFIG_ID>" }
```

and every detection decision — entities, token format, destinations, skip and
restrict — belongs to the saved configuration instead. The field is camelCase
only; `configuration_id` is refused as an unknown field. An id that does not
resolve reports `Field vault_id or configuration_id is missing in the request`,
which names the wrong problem, so the plugin requires `config_id` at config time
rather than letting that error reach an operator.

### Response

```json
{
  "processedText": "Hi, I'm [NAME_5RVywhc], SSN [SSN_0ZKyxTN], card [CREDIT_CARD_0Bg71FC].",
  "entities": [
    {
      "token": "NAME_5RVywhc",
      "value": "Jane Doe",
      "entityType": "NAME",
      "location": { "startIndex": 9, "endIndex": 17 },
      "entityScores": { "NAME": 0.926 }
    }
  ],
  "metrics": { "wordCount": 10, "characterCount": 55 }
}
```

The envelope is camelCase: `processedText`, and `entityType` on each entity. The
plugin reads both that and the older `entity_type` spelling, because a nil entity
class does not error — it silently files every count under `?` and disables
per-entity behaviour.

`entityScores` is per-entity detector confidence, which the older API did not
return. Nothing consumes it yet; it is what a confidence floor would be built on.

**Tokens are deterministic and stable across API versions.** The same value
yields the same token — `Jane Doe` → `[NAME_5RVywhc]` — which is what lets a token
minted on one conversation turn be resolved on a later one, and what made moving
between API versions a no-op rather than a migration.

## 3.4 Many spans per request

A chat payload contains many spans — every message's content, the system prompt,
each `tool_result` block. Each is de-identified with its own call, and the calls
run in concurrent waves of `operations.limits.max_concurrency` (default 8), so a
request costs roughly `ceil(spans / max_concurrency)` round trips rather than one
per span.

This matters more than it sounds. Measured on real traffic, Detect costs ~104 ms
per span at the median and ~403 ms at p90; sequentially, a large agent request
spent essentially all of its wall clock here — the worst observed was 26.3 s of a
31.4 s request.

`operations.limits.max_spans` caps the count and **fails closed**: over the limit
the request is refused with 413 rather than partly de-identified, because
forwarding a body where only some spans were processed would leak the remainder
while reporting success. Keep `max_concurrency <= keepalive_pool_size` or waves
contend for connections.

## 3.5 Re-hydration strategies

Selected by `config.reidentify.strategy`:

### 3.5.1 `reidentify_text` (default)

Best for free-text responses that contain tokens.

```http
POST /v2/detect/reidentify/string
```

```json
{
  "text": "I've emailed [NAME_aB3xQ] at [EMAIL_ADDRESS_kp2].",
  "vault_id": "<VAULT_ID>",
  "redacted_entities": ["SSN"],
  "masked_entities": ["CREDIT_CARD"],
  "plain_text_entities": ["NAME", "EMAIL_ADDRESS"]
}
```

Values are restored as plain text. The API also accepts a `redactionLevel` array
for server-side masking per entity type, which the plugin does not send: omitting
it returns full plaintext, and one local code path then covers both this
vault-authoritative route and the request-scoped `mapping_only` route. Response:

```json
{ "processed_text": "I've emailed Jane Doe at jane@acme.com.", "errors": [] }
```

> Entity treatment lets you re-identify *some* classes for the user while
> keeping the most sensitive ones masked even on the way back (e.g. show the
> name, mask the card).

### 3.5.2 `detokenize` (structured `VAULT_TOKEN`)

Best when re-identifying specific JSON fields whose entire value is a token.

```http
POST /v1/vaults/{vault_id}/detokenize
```

```json
{
  "detokenizationParameters": [
    { "token": "CREDIT_CARD_N92QAVa", "redaction": "PLAIN_TEXT" },
    { "token": "NAME_aB3xQ",          "redaction": "PLAIN_TEXT" }
  ]
}
```

Response (`redaction` ∈ `PLAIN_TEXT` | `MASKED` | `REDACTED`):

```json
{ "records": [ { "token": "CREDIT_CARD_N92QAVa", "value": "4111111111111111", "valueType": "STRING" } ] }
```

The plugin substitutes each token in the targeted field with its returned value.

### 3.5.3 `mapping_only` (no second Skyflow call)

If `token_format = ENTITY_UNQ_COUNTER`/`VAULT_TOKEN` and the response only ever
contains tokens that were minted on **this** request, the plugin can re-identify
purely from the in-memory request mapping — **zero** extra Skyflow round-trips
and zero risk of unauthorized detokenization. Limitation: cannot restore tokens
the model invented or that came from other requests. Offered as a latency-
optimized, governance-strict option.

## 3.6 Token↔value mapping model (`mapping.lua`)

Built during `access` from the De-identify `entities[]`:

```lua
ctx.mapping = {
  by_token = {
    ["NAME_aB3xQ"]        = { value = "Jane Doe",        entity = "NAME" },
    ["SSN_0ykQWPA"]       = { value = "123-45-6789",     entity = "SSN" },
  },
  entities_seen = { NAME = 2, SSN = 1, CREDIT_CARD = 1 },
}
```

- Lives only in `kong.ctx.plugin` for the request; GC'd at request end.
- Used by `mapping_only` re-identify directly, and to choose entity treatment
  for `reidentify_text`/`detokenize`.
- **Never** logged, never written to `kong.cache`, never shared between requests
  or workers.

## 3.7 Entity taxonomy

Common entities (subset; full list per your Detect configuration):
`NAME`, `SSN`, `CREDIT_CARD`, `CREDIT_CARD_EXPIRATION`, `EMAIL_ADDRESS`,
`PHONE_NUMBER`, `DOB`, `YEAR`, `STATISTICS`, plus address, MRN, IBAN, IP, etc.

The plugin does **not** hard-code the taxonomy — `config.deidentify.entities` is
a free list of strings validated as non-empty uppercase tokens, so new Skyflow
entities work without a plugin release. An empty list defers to Skyflow's
default detector set.

## 3.8 Error handling & mapping

`client.lua` normalizes Skyflow responses to a small result type
`{ ok=bool, status=int, data=table|nil, err=string|nil, retryable=bool }`.

| Skyflow condition | `client.lua` result | Handler action |
| ----------------- | -------------------- | -------------- |
| 200 + well-formed body | `ok=true` | proceed |
| 200 + `errors[]` non-empty | `ok=false, retryable=false` | posture per phase (deny / token-fallback) |
| 401 / token expired | `ok=false, retryable=true (once)` | refresh token, retry once, else deny |
| 403 (permission) | `ok=false, retryable=false` | deny + clear operator log ("grant Detect permission") |
| 429 | `ok=false, retryable=true` | bounded backoff retry (idempotent), then posture |
| 5xx / timeout / conn err | `ok=false, retryable=true` | bounded retry, then the `operations.on_error.skyflow` posture |
| Non-JSON / schema mismatch | `ok=false, retryable=false` | deny + log (treat as outage) |

- **Timeouts** are explicit (`connect`, `send`, `read`) from
  `config.timeout_ms` (default 5000) — the Skyflow SDKs have *no* built-in
  timeout, so the gateway owns this.
- **Retries** apply only to idempotent operations and respect a total
  `config.deadline_ms` so a slow Skyflow can't blow the request budget.

## 3.9 Worked end-to-end example (OpenAI-shaped body, de-identify + re-identify)

**Client → Kong**

```json
POST /v1/chat/completions
{ "model": "gpt-4o", "messages": [
  { "role": "user", "content": "Draft a reply to Jane Doe (jane@acme.com) about invoice 7782." } ] }
```

**Kong → OpenAI** (after de-identify; provider sees only tokens)

```json
{ "model": "gpt-4o", "messages": [
  { "role": "user", "content": "Draft a reply to [NAME_aB3xQ] ([EMAIL_ADDRESS_kp2]) about invoice 7782." } ] }
```

**OpenAI → Kong**

```json
{ "choices": [ { "message": { "role": "assistant",
  "content": "Hi [NAME_aB3xQ], regarding invoice 7782 ... I'll follow up at [EMAIL_ADDRESS_kp2]." } } ] }
```

**Kong → Client** (after re-identify; `NAME`,`EMAIL_ADDRESS` treated `plain_text`)

```json
{ "choices": [ { "message": { "role": "assistant",
  "content": "Hi Jane Doe, regarding invoice 7782 ... I'll follow up at jane@acme.com." } } ] }
```

OpenAI never saw `Jane Doe` or `jane@acme.com`; the user's experience is intact.
