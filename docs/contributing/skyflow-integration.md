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

The vault base URL is derived from the cluster:

```
https://{cluster_id}.vault.skyflowapis.com
```

| Operation | Method & path | Used for |
| --------- | ------------- | -------- |
| De-identify text | `POST /v1/detect/deidentify/string` | Tokenize PII in outbound request text |
| Re-identify text | `POST /v1/detect/reidentify/string` **(confirm path)** | Restore values into response text |
| Detokenize | `POST /v1/vaults/{vault_id}/detokenize` | Per-token re-hydration of structured fields (`VAULT_TOKEN`) |
| Auth (SA token) | `POST {tokenURI}` (e.g. `https://manage.skyflowapis.com/v1/auth/sa/oauth/token`) | Mint bearer token from a service account |

`env` selects the deployment (`PROD`, `SANDBOX`, `DEV`, `STAGE`); for non-prod
the host may differ (e.g. `*.vault.skyflowapis.dev`) — exposed via
`config.skyflow_base_url_override` for self-managed / private-cloud tenants.

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
  credential, with TTL = `expiresIn − config.token_skew_seconds` (default 300).
- **Single-flight**: concurrent requests that find the token missing/expired
  coordinate via `lua-resty-lock` (mlcache does this) so only one mint happens.
- On a `401` mid-flight (token expired between check and use), the client does
  **one** forced refresh + retry, then surfaces the error.
- Required Skyflow role permission: **"De-identify and reidentify sensitive data
  in text and files."** Detokenize additionally needs record read/detokenize
  permission on the relevant column(s).

## 3.3 De-identify operation

### Request (`deidentify_text`)

```http
POST /v1/detect/deidentify/string
Authorization: Bearer <token>
X-SKYFLOW-ACCOUNT-ID: <account_id>        # (confirm: required on some tenants)
Content-Type: application/json
```

```json
{
  "text": "Hi, I'm Jane Doe, SSN 123-45-6789, card 4111111111111111.",
  "vault_id": "<VAULT_ID>",
  "entities": ["NAME", "SSN", "CREDIT_CARD", "EMAIL_ADDRESS", "PHONE_NUMBER"],
  "token_type": { "default": "VAULT_TOKEN" },
  "allow_regex_list": [],
  "restrict_regex_list": [],
  "transformations": {
    "shift_dates": { "max_days": 30, "min_days": 10, "entities": ["DOB"] }
  }
}
```

| Field | Maps from plugin config | Notes |
| ----- | ----------------------- | ----- |
| `text` | the extracted span(s) | one span per call, or batched (§3.4) |
| `vault_id` | `config.vault_id` | — |
| `entities` | `config.deidentify.entities` | empty/omitted ⇒ Skyflow default detectors |
| `token_type.default` | `config.deidentify.token_format` | `VAULT_TOKEN` \| `ENTITY_ONLY` \| `ENTITY_UNQ_COUNTER` |
| `allow_regex_list` / `restrict_regex_list` | `config.deidentify.allow_regex` / `restrict_regex` | custom allow/deny patterns |
| `transformations.shift_dates` | `config.deidentify.shift_dates` | optional date-shifting |

### Response

```json
{
  "processed_text": "Hi, I'm [NAME_aB3xQ], SSN [SSN_0ykQWPA], card [CREDIT_CARD_N92QAVa].",
  "entities": [
    { "token": "NAME_aB3xQ",        "value": "Jane Doe",            "entity": "NAME",        "scores": { "NAME": 0.97 } },
    { "token": "SSN_0ykQWPA",       "value": "123-45-6789",         "entity": "SSN",         "scores": { "SSN": 0.94 } },
    { "token": "CREDIT_CARD_N92QAVa","value": "4111111111111111",   "entity": "CREDIT_CARD", "scores": { "CREDIT_CARD": 0.99 } }
  ],
  "word_count": 11,
  "char_count": 59
}
```

The plugin:

1. Writes `processed_text` back into the originating span (`body.lua`).
2. Records each `entities[]` item into the request-scoped **mapping**
   (`token → {value, entity}`) for later re-identification.
3. Emits a metric with detected-entity **counts by type** (never values).

> **Token formats.** Use `VAULT_TOKEN` when you intend to re-identify
> (reversible, stored in the vault). Use `ENTITY_ONLY` for pure one-way
> redaction (e.g. logging, fine-tuning corpora) — no re-identification possible.
> `ENTITY_UNQ_COUNTER` yields stable, human-readable labels (`NAME_1`, `NAME_2`)
> useful for prompt readability while staying reversible within a request.

## 3.4 Batching multiple spans

Chat payloads contain many spans (`messages[*].content`). Two strategies,
selectable via `config.deidentify.batch_mode`:

| Mode | How | When |
| ---- | --- | --- |
| `per_span` (default) | One Detect call per span, issued **concurrently** (bounded by `config.max_concurrency`) using `ngx.thread.spawn` | Cleanest mapping; preserves per-span boundaries; concurrency keeps latency ≈ one round-trip |
| `joined` | Concatenate spans with a unique sentinel (`\0<idx>\0`), one Detect call, split on the sentinel afterward | Fewest API calls; requires sentinel that Detect won't tokenize/alter (validated in tests) |

`per_span` is the safe default. The handler caps total spans
(`config.max_spans`) and total bytes (`config.max_body_size`).

## 3.5 Re-hydration strategies

Selected by `config.reidentify.strategy`:

### 3.5.1 `reidentify_text` (default)

Best for free-text responses that contain tokens.

```http
POST /v1/detect/reidentify/string        # (confirm path)
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

Each entity type is restored as **plain text**, **masked**, or kept **redacted**
per `config.reidentify.entity_treatment`. Response:

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
| 5xx / timeout / conn err | `ok=false, retryable=true` | bounded retry, then `on_skyflow_error` posture |
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
