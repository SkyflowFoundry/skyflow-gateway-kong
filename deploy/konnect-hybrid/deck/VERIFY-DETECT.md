# Skyflow Detect API contract (verified against a live vault 2026-07-01)

`handler.lua` was originally built against the mock, which accepted anything —
its field names were wrong. The real contract below is now verified and the
handler matches it. Keep this as the reference if you touch `deidentify_text()`.

## 1. What the plugin sends
`POST https://<cluster_id>.vault.skyflowapis.com/v1/detect/deidentify/string`
```
Authorization: Bearer <api_key>
X-SKYFLOW-ACCOUNT-ID: <account_id>     # only if config.account_id is set
Content-Type: application/json
```
```json
{
  "text": "...",
  "vault_id": "<vault_id>",
  "entity_types": ["name","email_address"],
  "token_type": { "default": "entity_unq_counter" }
}
```

## 2. What the plugin expects back
```json
{ "processed_text": "... [NAME_1] ...",
  "entities": [ { "token": "NAME_1", "value": "Jane Doe", "entity_type": "NAME" } ] }
```
It reads `data.processed_text` and `data.entities[].{token,value,entity_type}`
(see `handler.lua` → `deidentify_text()` / the access loop). Enum values
(`entity_types`, `token_type.default`) are **lowercase on the wire**; config
uses uppercase for readability and the handler downcases at send time.

## 3. Probe the live API
```bash
curl -s https://<cluster_id>.vault.skyflowapis.com/v1/detect/deidentify/string \
  -H "Authorization: Bearer <API_KEY>" -H 'Content-Type: application/json' \
  -d '{"text":"Email Jane Doe at jane@acme.com","vault_id":"<VAULT_ID>","token_type":{"default":"entity_unq_counter"}}' | jq .
```

## 4. If it doesn't match — where to fix (all in `handler.lua`)
| Mismatch | Fix |
| --- | --- |
| Auth rejected (401) with `Bearer <api_key>` | Confirm API-key scheme; if it needs a service-account bearer, mint one (SA-JWT is a TODO in the single-file build). |
| `token_type` enum is lowercase on the wire (`vault_token`) | In `deidentify_text()`, lowercase `d.token_format` before sending. |
| Field is `entity_types` not `entities` (or similar) | Rename in the `payload` table in `deidentify_text()`. |
| Response is camelCase (`processedText`, `records`, …) | Update the two reads in `deidentify_text()`: `data.processed_text` and the `e.token/e.value/e.entity` loop. |
| 403 | Grant the service the **"De-identify and reidentify sensitive data in text and files"** permission. |

## 5. Re-identify (vault-backed round-trip)
With `deidentify.token_format: VAULT_TOKEN` + `reidentify.strategy: reidentify_text`,
the response phase resolves the vault tokens the LLM echoes back by POSTing each
response text span to:

`POST /v1/detect/reidentify/string`
```json
{ "text": "... <vault_token> ...", "vault_id": "<vault_id>" }
```
Expected back (handler reads `data.processed_text`, falls back to `data.text`):
```json
{ "processed_text": "... Jane Doe ..." }
```

**Probe it** — paste a real token from the de-id probe above:
```bash
curl -s https://<cluster_id>.vault.skyflowapis.com/v1/detect/reidentify/string \
  -H "Authorization: Bearer <API_KEY>" -H 'Content-Type: application/json' \
  -d '{"text":"hello <VAULT_TOKEN>","vault_id":"<VAULT_ID>"}' | jq .
```
If the response field isn't `processed_text` (or `text`), update `skyflow_reidentify()`
in `handler.lua`. If re-id needs its own request fields, add them to that payload.

Notes:
- Only **VAULT_TOKEN** de-id is re-identifiable — `ENTITY_*` tokens aren't stored
  in the vault. The schema enforces `reidentify_text` ⇒ `VAULT_TOKEN`.
- Re-id only restores tokens the model actually **echoes back**; if the LLM
  paraphrases a token away, there is nothing to resolve.
- `reidentify_text` restores plaintext; per-entity `masked`/`redacted` treatments
  are a `mapping_only`-only feature.

## 6. Then
Sync `real-vault.yaml` (already set to VAULT_TOKEN + reidentify_text; see its
header). Re-run the `/ai/chat` curl and confirm vault tokens go to the LLM and
real values come back to the client.
