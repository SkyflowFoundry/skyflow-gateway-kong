#!/usr/bin/env bash
# Act 2 — a real coding-agent CLI (opencode) working through the Kong AI Gateway.
#
# opencode is pointed at the gateway's OpenAI-compatible endpoint. It reads
# patient_intake.py (full of synthetic PHI) and reasons over it via gpt-4o-mini —
# but Kong + Skyflow de-identify every PHI value on the way to OpenAI and
# re-identify it on the way back. OpenAI only ever sees [NAME_xjv74g]-style
# tokens; the developer sees real names in the agent's answers.
#
# The tokens are deterministic (VAULT_TOKEN), so "Maria Gonzalez" resolves to the
# SAME token in every turn — that referential integrity is what lets the model
# keep the two patients straight without ever learning who they are.
#
# Usage (from repo root or this dir):
#   ./demo/act2/run.sh            # real: gateway :8000 -> real OpenAI
#   REHEARSE=1 ./demo/act2/run.sh # plumbing only: gateway :8010 -> mock LLM (echoes)
#
# Prereqs:
#   - opencode installed:  curl -fsSL https://opencode.ai/install | bash
#   - the target gateway up (see repo README). Real run needs the Konnect DP (:8000)
#     with real-vault.yaml synced; rehearsal needs local-dbless (:8010).
set -euo pipefail

cd "$(dirname "$0")"                      # so opencode operates on ./patient_intake.py

# :8000 = Konnect DP (real vault + real OpenAI). REHEARSE -> :8010 local mocks.
if [ "${REHEARSE:-0}" = "1" ]; then
  export KONG_AI_BASE_URL="http://localhost:8010/ai/v1"
else
  export KONG_AI_BASE_URL="${KONG_AI_BASE_URL:-http://localhost:8000/ai/v1}"
fi
# Dummy key — Kong's ai-proxy injects the real OpenAI key upstream, so the agent
# never holds it. (A secret-management win worth calling out on camera.)
export OPENAI_API_KEY="${OPENAI_API_KEY:-sk-dummy-kong-injects-the-real-one}"
export OPENCODE_CONFIG="$PWD/opencode.json"

MODEL="kong/gpt-4o-mini"

# The opencode installer drops the binary in ~/.opencode/bin, which isn't on
# PATH in a non-login shell — add it so this script works from anywhere.
export PATH="$HOME/.opencode/bin:$PATH"
command -v opencode >/dev/null 2>&1 || {
  echo "opencode not found. Install: curl -fsSL https://opencode.ai/install | bash" >&2
  exit 1
}

echo "▶ gateway: $KONG_AI_BASE_URL   model: $MODEL"
echo "▶ OpenAI will only ever see Skyflow tokens — watch the gateway logs to confirm."
echo

# Continue the same session across turns when supported; fall back to a fresh
# session (each prompt is self-contained and re-reads the file, so the vault still
# hands out the same token either way).
run_turn() {
  local prompt="$1"; shift
  opencode run -m "$MODEL" "$@" "$prompt" 2>&1
}

# Read-only tasks (tools write/edit/bash/webfetch/task are disabled in
# opencode.json) — the agent reasons over the PHI, it never edits the repo or
# spins sub-agents. Keeps the recording clean and deterministic.
echo "════ Turn 1 — summarize meds + flag interaction risks ════"
run_turn "Read patient_intake.py and summarize each patient's active medications, flagging any obvious drug-interaction risks. Do not modify any files."

echo
echo "════ Turn 2 — draft a follow-up for one patient (same session) ════"
run_turn "Using the details in patient_intake.py, draft a two-sentence appointment-reminder message for Maria Gonzalez." --continue \
  || run_turn "Using the details in patient_intake.py, draft a two-sentence appointment-reminder message for Maria Gonzalez."

echo
echo "✔ Done. The agent saw real names; OpenAI saw only [TOKEN]s. Check gateway logs:"
echo "    docker logs skyflow-kong-dp 2>&1 | grep -i deidentif   # or the DP you used"
