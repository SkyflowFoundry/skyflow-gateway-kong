# Demo recording

`steps.sh` is the on-camera script for this project's demo. One PII prompt runs
through the Konnect data plane (`:8000`, real Skyflow vault) in two groups:

**What the LLM sees** — before vs after, both via an echo upstream that reflects
the request the model would receive:

1. **Raw: prompts with PII hit AI** — `/demo/raw` (no de-identify plugin) echoes
   the request unchanged: the raw PII an unprotected upstream would get.
2. **De-identified: what the LLM receives** — `/demo/deid` de-identifies first,
   so the echo shows the tokenized prompt (`[NAME_…]`, `[EMAIL_ADDRESS_…]`,
   `[PHONE_NUMBER_…]`) — same prompt, no raw PII.

**Using the gateway — de-identify + re-identify:**

- **Re-identified response** — `/ai/chat`: prompt de-identified → real OpenAI →
  response re-identified by Skyflow. A useful answer, PII never exposed to the model.

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

Outputs land in `demo-out/` (git-ignored). The **Re-identified response** step
hits real OpenAI — redact anything sensitive before sharing, or record with
`INCLUDE_LIVE=0` (which skips it, leaving the two echo-based steps that only use
the vault).

## The `/demo/raw` and `/demo/deid` echo routes

The "what the LLM sees" contrast uses two routes onto the same echo upstream:
`/demo/raw` (no plugin → reflects the raw PII) and `/demo/deid` (de-identify
**only**, re-identify disabled → reflects the tokens). Re-identify must be *off*
on `/demo/deid` — otherwise it would restore the tokens in the echoed body and
you'd see no proof. Both live in `deploy/konnect-hybrid/deck/real-vault.yaml`:

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
