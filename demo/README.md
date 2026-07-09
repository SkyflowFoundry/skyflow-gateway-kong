# Demo recording

The demo is in two acts:

- **Act 1 — `steps.sh`** (the curls below): the mechanism, on camera.
- **Act 2 — [`act2/`](act2/)**: the use case — a real coding-agent CLI (opencode)
  working through the gateway. See [act2/README.md](act2/README.md).

## Act 1 — `steps.sh`

One healthcare prompt (a patient follow-up note, dense with PHI) runs through the
Konnect data plane (`:8000`, real Skyflow vault). The prompt, highlight list, and
recurring-patient pair come from a **swappable scenario file**
([scenarios/healthcare.sh](scenarios/healthcare.sh)) — re-skin for another vertical
with `SCENARIO=demo/scenarios/<name>.sh` and nothing in `steps.sh` changes.

The one note lights up ~12 entity types — `NAME`, `NAME_MEDICAL_PROFESSIONAL`,
`HEALTHCARE_NUMBER`, `ORGANIZATION_MEDICAL_FACILITY`, `CONDITION`, `DRUG`, `DOSE`,
`EMAIL_ADDRESS`, `PHONE_NUMBER` … — several with multiple instances of the same
type (two patients, two drugs, two conditions), so breadth and referential
integrity are both visible in one frame.

1. **What the LLM sees without Skyflow** — `/demo/raw` (no plugin) echoes the
   request unchanged: the raw PHI an unprotected upstream would get.
2. **What the LLM sees with Skyflow** — `/demo/deid` de-identifies first, so the
   echo shows the tokenized prompt (`[NAME_xjv74g]`, `[HEALTHCARE_NUMBER_…]`,
   `[DRUG_…]` …) — same prompt, no raw PHI.
3. **What the caller gets back** — `/ai/chat`: prompt de-identified → real OpenAI →
   response re-identified by Skyflow. A useful answer, PHI never exposed to the model.
4. **Same patient → same token** — two *separate* requests both mentioning the
   patient. With `VAULT_TOKEN` the mapping is deterministic per value, so the
   `[NAME_…]` token is **identical** in both — the referential integrity that lets
   a multi-turn conversation (Act 2) stay coherent.

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

Outputs land in `demo-out/` (git-ignored). Step 3 (**re-identified response**)
hits real OpenAI — redact anything sensitive before sharing, or record with
`INCLUDE_LIVE=0` (which skips it, leaving steps 1, 2, and 4, which only use the
vault via the echo routes).

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
every route the demo uses (`/demo/raw`, `/demo/deid`, `/ai/chat`, and the
OpenAI-compatible `/ai/v1/chat/completions` that Act 2's opencode hits) and is the
file kept synced to the `skyflow-hybrid` control plane.

> ⚠️ **The control plane is shared and `deck gateway sync` is destructive** — it
> makes the CP match the synced file exactly and deletes anything not in it. If a
> teammate syncs a different deck file (`kong.yaml`, `ai-gateway.yaml`), these
> routes disappear and the demo 404s. **Fix:** re-sync `real-vault.yaml` (needs
> `KONNECT_PAT`, `DECK_OPENAI_API_KEY`, `DECK_SKYFLOW_*` exported).

See the skill's `SKILL.md` for the full recorder reference (screen selection,
audio, cropping, re-processing a capture).
