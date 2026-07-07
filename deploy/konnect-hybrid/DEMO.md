# Demo & next steps (Konnect hybrid)

Status: **working**. Self-managed DP on Konnect runs `skyflow-deidentify`;
de-identify **and** the vault-backed re-identify round-trip are working.

## What's proven

Prompt PII is tokenized before it reaches the LLM, then restored on the way back:

```
client req:   "Email Jane Doe at jane@acme.com"
LLM sees:     "Email [NAME_aB3xQ] at [EMAIL_ADDRESS_kp2]"   # only tokens
client resp:  "... Jane Doe ... jane@acme.com ..."          # values restored via the vault
```

## Demo script

1. **De-identify** (the win): the basic curl → inspect echoed `body`, PII is tokens.
2. **More entities**: send SSN / card / phone; show they tokenize too.
3. **Fail-closed** (no silent leak):
   - `docker compose stop mock-skyflow` → curl → expect **502**, upstream not called.
   - `docker compose start mock-skyflow`.
4. **dry_run**: set `dry_run: true` in `deck/kong.yaml`, re-sync → detections logged, body unchanged.
5. **Re-identify round-trip** (`deck/ai-gateway.yaml`, needs `DECK_OPENAI_API_KEY`):
   curl `/ai/chat` with a fixture name → the LLM only sees tokens, the client gets
   real values back (`VAULT_TOKEN` + `reidentify_text`; the mock reverses them).

## Next improvements (before a polished demo)

- **Broader coverage**: multiple messages (batching), `anthropic`/`mcp` profiles,
  large bodies, streaming responses (streamed LLM output can't be re-identified in
  `buffer` mode — the common chat UX still needs a story here).
- **Treatments on the vault path**: `reidentify_text` restores plaintext only;
  per-entity `masked`/`redacted` currently need `mapping_only`. Could apply
  treatments to the reidentify response if it returns `entities[]`.
- **Kit polish**: let the DP take the cluster cert **inline** (env) as Konnect's
  own `docker run` does, to avoid the PEM-file friction from setup.

## Ready-to-run configs (in `deck/`)

- `ai-gateway.yaml` — `skyflow-deidentify` + `ai-proxy` to a real LLM (mock
  Skyflow), via the **nested-proxy** routes (`/ai/chat` front does de-id + re-id
  and loops back to the internal `/_ai_upstream` route running `ai-proxy` alone —
  they can't share a route, see the repo README). `/ai/chat` does the full
  round-trip (`VAULT_TOKEN` + `reidentify_text`); `/demo/chat` keeps
  `mapping_only` to show masked/redacted treatments. Set `DECK_OPENAI_API_KEY`,
  then sync.
- **`real-vault.yaml` — the canonical / default demo config.** Same AI route
  against a **real Skyflow vault** via `DECK_SKYFLOW_*` envs (`VAULT_TOKEN` +
  `reidentify_text`), **plus** the `/demo/deid` token-proof route (de-identify
  only, re-identify OFF, echo upstream) that the recorded demo (`demo/steps.sh`)
  drives. This is the file kept synced to the CP — sync it, not the others,
  unless you specifically want the mock/echo variants.
- `VERIFY-DETECT.md` — checklist to confirm the live Detect **de-id and re-id**
  contracts match the plugin (do this before `real-vault.yaml`).
- ⚠️ `deck gateway sync` makes the control plane match the synced file EXACTLY
  and **deletes anything not in it**. The CP is shared — syncing `kong.yaml` or
  `ai-gateway.yaml` will remove `real-vault.yaml`'s routes (`/vault/chat`,
  `/ai/chat`, `/demo/deid`) and break the demo. To restore, re-sync
  `real-vault.yaml`. Sync one file at a time and treat `real-vault.yaml` as the
  default.

## Housekeeping

- **Rotate the Konnect PAT** used during setup.
- Plugin is unit-tested (pure fns); live de-identify + vault-backed re-identify
  verified. Other profiles (`anthropic`/`mcp`) and streaming are not yet
  exercised against real traffic.
