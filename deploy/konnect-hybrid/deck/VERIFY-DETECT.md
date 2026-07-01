# Verify the real Skyflow Detect API before going off the mock

The mock accepted whatever we sent, so `handler.lua`'s Detect request/response
field names are **unverified against a live vault**. Do this ~10-min check first;
if anything differs, make the small edits noted below.

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
  "entities": ["NAME","EMAIL_ADDRESS"],
  "token_type": { "default": "ENTITY_UNQ_COUNTER" }
}
```

## 2. What the plugin expects back
```json
{ "processed_text": "... [NAME_1] ...",
  "entities": [ { "token": "NAME_1", "value": "Jane Doe", "entity": "NAME" } ] }
```
It reads `data.processed_text` and `data.entities[].{token,value,entity}`
(see `handler.lua` → `deidentify_text()`).

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

## 5. Re-identify note
`mapping_only` restores only tokens the model echoes verbatim. Real random
`VAULT_TOKEN`s may get rewritten by the model → prefer `ENTITY_UNQ_COUNTER` for
demos, or implement the `reidentify_text`/`detokenize` strategy (follow-up) to
restore regardless.

## 6. Then
Set the envs and sync `real-vault.yaml` (see its header). Re-run the `/ai/chat`
curl and confirm real vault tokens go to the LLM and real values come back.
