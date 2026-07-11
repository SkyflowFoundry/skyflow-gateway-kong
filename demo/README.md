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

### Record it (VHS)

The canonical recording is a **VHS** tape — [`act1.tape`](act1.tape) — that runs the
**real** curls and re-renders on demand (same approach as
[Act 2](act2/README.md#record-it-vhs)):

```bash
cd demo && vhs act1.tape           # -> ../demo-out/act1.{gif,mp4}
```

It's deliberately minimal: the three-beat core — **raw PHI → de-identified tokens →
re-identified answer**. Beats 1 and 2 land adjacent so the contrast (real names vs
`[NAME_…]`) reads in a single frame; beat 3 clears to its own screen for the real
re-identified answer while OpenAI only ever saw the tokens. (Step 4, the same-token
referential-integrity proof, is left to `steps.sh` to keep the tape lean.)

Each beat pipes through `hi` (from [`highlight.sh`](highlight.sh), sourced in the hidden
setup) so **raw PII shows red and Skyflow tokens show green** — the same colour cue as
the original `record-demo` recording. The red-PII list comes from the scenario's
`$HL_SENSITIVE`, so re-skinning the scenario re-skins the highlighting for free.

A hidden setup block sets `$DEMO_HOST` and sources
[`scenarios/healthcare.sh`](scenarios/healthcare.sh) — so the visible commands stay short
(`-d "$PROMPT"`) instead of a screenful of inline JSON. It `Source`s Act 2's
[`config.tape`](act2/config.tape) for a matched look.

Two things that bite:

- **The tape runs under `bash`, not `zsh`.** The scenario sets a `$PROMPT` variable, and
  in **zsh `PROMPT` is a synonym for `$PS1`** — sourcing the scenario would overwrite the
  prompt with the JSON blob (and the bare `Wait` never re-matches the `$` prompt). bash treats
  `PROMPT` as an ordinary variable. `Set Shell bash` overrides the zsh in `config.tape`.
- **`jq` must be on PATH.** VHS's shell skips `~/.zshrc`/`~/.bashrc`, so the tape exports
  `/opt/homebrew/bin` (Homebrew `jq`) explicitly. `curl` is `/usr/bin`, always present.
- **Not byte-identical.** Beat 3 hits real OpenAI, so the answer's wording varies per
  run. The mechanism reproduces; keep the render you like.

The older **`record-demo.sh`** path (from the personal `demo-media` skill —
<https://github.com/jstjoe/claude-sample>, `skills/demo-media/`) still works and drives
the same [`steps.sh`](steps.sh) (which also does step 4); VHS is now the recommended way.

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
