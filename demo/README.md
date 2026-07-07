# Demo recording

`steps.sh` is the on-camera script for this project's demo — the labeled sequence
of `curl`s that shows the de-identify → LLM → re-identify round-trip.

It's driven by **`record-demo.sh`** from the personal `demo-media` skill, which
screen-records, runs these steps, and emits a timestamped MP4 (for a talk track)
plus a GIF (for inline sharing). The recorder lives with the skill, not here:
<https://github.com/jstjoe/claude-sample> (`skills/demo-media/`).

## Use

1. Bring the demo stacks up (see the repo README): local-dbless proxy on `:8010`,
   Konnect-hybrid data plane on `:8000`.
2. Make `record-demo.sh` available — install the skill (`claude-sample/install.sh`
   symlinks it into `~/.claude/skills/demo-media/`) and run it from there, or copy
   the script locally.
3. From the repo root:

   ```bash
   record-demo.sh --steps demo/steps.sh              # record -> demo-out/<stamp>.{mp4,gif}
   record-demo.sh --steps demo/steps.sh --no-record  # rehearse the curls, no capture
   INCLUDE_LIVE=0 record-demo.sh --steps demo/steps.sh   # skip the real-OpenAI step
   ```

Outputs land in `demo-out/` (git-ignored). The live step hits real OpenAI —
redact anything sensitive before sharing, or record with `INCLUDE_LIVE=0`.

See the skill's `SKILL.md` for the full recorder reference (screen selection,
audio, cropping, re-processing a capture).
