# Demo recording

`steps.sh` is the on-camera script for this project's demo. It tells the whole
value story in three requests against the Konnect data plane (`:8000`, real
Skyflow vault):

1. **What your LLM vendor actually receives** — `/demo/deid` de-identifies then
   echoes the request back, so you *see* the tokenized body the upstream got
   (`[NAME_…]`, `[EMAIL_ADDRESS_…]`, `[PHONE_NUMBER_…]`) — no raw PII.
2. **What your caller gets back** — the same request through de-id → LLM → re-id
   returns the real details, though the model only ever processed tokens.
3. **End-to-end on real OpenAI** — a useful answer, PII protected in transit.

It's driven by **`record-demo.sh`** from the personal `demo-media` skill, which
screen-records, runs these steps, and emits a timestamped MP4 (for a talk track)
plus a GIF (for inline sharing). The recorder lives with the skill, not here:
<https://github.com/jstjoe/claude-sample> (`skills/demo-media/`).

## Use

1. Bring up the Konnect-hybrid data plane (see the repo README) so `:8000` is live.
2. Make `record-demo.sh` available — install the skill (`claude-sample/install.sh`
   symlinks it into `~/.claude/skills/demo-media/`) and run it from there, or copy
   the script locally.
3. From the repo root:

   ```bash
   record-demo.sh --steps demo/steps.sh              # record -> demo-out/<stamp>.{mp4,gif}
   record-demo.sh --steps demo/steps.sh --no-record  # rehearse the curls, no capture
   INCLUDE_LIVE=0 record-demo.sh --steps demo/steps.sh   # skip the real-OpenAI step
   ```

Outputs land in `demo-out/` (git-ignored). Step 3 hits real OpenAI — redact
anything sensitive before sharing, or record with `INCLUDE_LIVE=0`.

## The `/demo/deid` proof route

Step 1 needs a de-identify-**only** route (re-identify disabled) pointed at the
echo upstream — otherwise re-identify would restore the tokens in the echoed body
and you'd see no proof. That route (`demo-echo` → `/demo/deid`) lives in
`deploy/konnect-hybrid/deck/real-vault.yaml` and is applied with:

```bash
deck gateway sync --konnect-token "$KONNECT_PAT" \
  --konnect-control-plane-name skyflow-hybrid \
  deploy/konnect-hybrid/deck/real-vault.yaml
```

(`deck gateway sync` deletes anything not in the file, so keep the full desired
state there. `DECK_OPENAI_API_KEY` and `DECK_SKYFLOW_*` must be exported.)

See the skill's `SKILL.md` for the full recorder reference (screen selection,
audio, cropping, re-processing a capture).
