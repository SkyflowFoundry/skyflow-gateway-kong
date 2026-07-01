# Demo & next steps (Konnect hybrid)

Status: **working**. Self-managed DP on Konnect runs `skyflow-deidentify`;
request de-identify verified end-to-end.

## What's proven
Prompt PII is tokenized before it reaches the upstream:
```
client:   "Email Jane Doe at jane@acme.com"
upstream: "Email [NAME_aB3xQ] at [EMAIL_ADDRESS_kp2]"   # echo shows what the LLM received
```

## Demo script
1. **De-identify** (the win): the basic curl → inspect echoed `body`, PII is tokens.
2. **More entities**: send SSN / card / phone; show they tokenize too.
3. **Fail-closed** (no silent leak):
   - `docker compose stop mock-skyflow` → curl → expect **502**, upstream not called.
   - `docker compose start mock-skyflow`.
4. **dry_run**: set `dry_run: true` in `deck/kong.yaml`, re-sync → detections logged, body unchanged.

## Next improvements (before a polished demo)
- **Show re-identify round-trip** (biggest gap): current `echo` isn't LLM-shaped, so
  response re-identify doesn't fire. Either
  (a) add a mock "LLM" upstream returning OpenAI JSON containing the tokens
      (`{"choices":[{"message":{"content":"... [NAME_aB3xQ] ..."}}]}`), or
  (b) chain the bundled **ai-proxy** plugin to a real LLM.
  Then the client sees real values restored while the LLM only saw tokens.
- **Real Skyflow vault**: drop `skyflow_base_url_override`; set real
  `vault_id`/`cluster_id` + an API key with the Detect permission. Validate the
  Detect request/response field names (the "confirm" items in
  `docs/03-skyflow-integration.md`) against the live API.
- **Broader coverage**: multiple messages (batching), `anthropic`/`mcp` profiles,
  large bodies, streaming responses.
- **Kit polish**: let the DP take the cluster cert **inline** (env) as Konnect's
  own `docker run` does, to avoid the PEM-file friction from setup.

## Ready-to-run configs (in `deck/`)
- `ai-gateway.yaml` — chains `skyflow-deidentify` + `ai-proxy` to a real LLM
  (mock Skyflow), keeps the echo route. Full de-id + re-id round-trip. Set
  `DECK_OPENAI_API_KEY`, then sync.
- `real-vault.yaml` — same AI route but against a **real Skyflow vault** via
  `DECK_SKYFLOW_*` envs.
- `VERIFY-DETECT.md` — 10-min checklist to confirm the live Detect API matches
  the plugin (do this before `real-vault.yaml`).
- ⚠️ `deck gateway sync` deletes anything not in the synced file — each file is a
  full desired state; sync one at a time.

## Housekeeping
- **Merge PR #3** (the functional plugin + this hybrid kit).
- **Rotate the Konnect PAT** used during setup.
- Plugin is unit-tested (pure fns) + live de-identify verified; re-identify and
  other profiles are not yet exercised against real traffic.
