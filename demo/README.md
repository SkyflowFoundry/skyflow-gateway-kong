# Demo recording

`steps.sh` is the on-camera script for this project's demo. It tells the whole
value story in four requests against the Konnect data plane (`:8000`, real
Skyflow vault):

1. **Raw: prompts with PII hit AI** — `/_ai_upstream` is the ai-proxy passthrough
   with *no* de-identify plugin, so the raw PII prompt goes straight to OpenAI.
   The "before" — this is the risk.
2. **De-identified: what the LLM receives** — `/demo/deid` de-identifies then
   echoes the request, so you *see* the tokenized prompt the model would get
   (`[NAME_…]`, `[EMAIL_ADDRESS_…]`, `[PHONE_NUMBER_…]`) — no raw PII.
3. **Re-identified prompt: prompts can be re-identified on demand** — `/vault/chat`
   de-identifies, the mock LLM echoes the tokens back, and Skyflow re-identifies
   them, restoring the original prompt.
4. **Re-identified response** — `/ai/chat`: prompt de-identified → real OpenAI →
   response re-identified by Skyflow. Same useful answer as step 1, PII never
   exposed to the model.

It's driven by **`record-demo.sh`** from the personal `demo-media` skill, which
screen-records, runs these steps, and emits a timestamped MP4 (for a talk track)
plus a GIF (for inline sharing). The recorder lives with the skill, not here:
<https://github.com/jstjoe/claude-sample> (`skills/demo-media/`).

## Use

1. Bring up the Konnect-hybrid data plane (see the repo README) so `:8000` is live.
2. Get the `record-demo` command — clone <https://github.com/jstjoe/claude-sample>
   and run `./install.sh`. It symlinks the `demo-media` skill into `~/.claude/skills/`
   and drops a `record-demo` command on your PATH (`~/.local/bin`). One-time, per machine.
3. From the repo root:

   ```bash
   record-demo --steps demo/steps.sh              # record -> demo-out/<stamp>.{mp4,gif}
   record-demo --steps demo/steps.sh --no-record  # rehearse the curls, no capture
   INCLUDE_LIVE=0 record-demo --steps demo/steps.sh   # skip the real-OpenAI step
   ```

Outputs land in `demo-out/` (git-ignored). Steps 1 and 4 hit real OpenAI —
redact anything sensitive before sharing, or record with `INCLUDE_LIVE=0` (which
skips both, leaving the de-identify/re-identify steps that only use the vault).

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

`real-vault.yaml` is the **canonical / default** config for this demo — it holds
all three routes the steps use (`/demo/deid`, `/vault/chat`, `/ai/chat`) and is
the file kept synced to the `skyflow-hybrid` control plane.

> ⚠️ **The control plane is shared and `deck gateway sync` is destructive** — it
> makes the CP match the synced file exactly and deletes anything not in it. If a
> teammate syncs a different deck file (`kong.yaml`, `ai-gateway.yaml`), these
> routes disappear and the demo 404s. **Fix:** re-sync `real-vault.yaml` (needs
> `KONNECT_PAT`, `DECK_OPENAI_API_KEY`, `DECK_SKYFLOW_*` exported).

See the skill's `SKILL.md` for the full recorder reference (screen selection,
audio, cropping, re-processing a capture).
