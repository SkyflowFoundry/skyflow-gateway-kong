# Demo steps for the skyflow-kong-poc live demo.
#
# Driven by record-demo.sh from the personal demo-media skill (see demo/README.md).
# Run from the repo root:
#   record-demo --steps demo/steps.sh              # record MP4 + GIF
#   record-demo --steps demo/steps.sh --no-record  # rehearse the curls only
#
# All steps hit the Konnect-hybrid data plane (:8000) backed by the real Skyflow
# vault. Content (the prompt, the highlight list, the recurring pair) comes from a
# swappable SCENARIO file so the demo can be re-skinned per vertical without
# touching this script. INCLUDE_LIVE=0 skips the real-OpenAI step.

DEMO_TITLE="Skyflow × Kong AI Gateway"

# DEMO_HOST, not HOST: zsh exports HOST=<hostname>, which would override a bare
# ${HOST:-...} and send the demo curls to the wrong host.
DEMO_HOST="${DEMO_HOST:-localhost:8000}"   # Konnect-hybrid data plane (real Skyflow vault)

# Content layer. Swap verticals with SCENARIO=demo/scenarios/<name>.sh.
# Provides: PROMPT, HL_SENSITIVE, RECUR_PROMPT_A, RECUR_PROMPT_B, SCENARIO_LABEL.
SCENARIO="${SCENARIO:-demo/scenarios/healthcare.sh}"
# shellcheck source=demo/scenarios/healthcare.sh
. "$SCENARIO"

demo() {
  # echo: calling OpenAI via Kong with echo back
  step "1 · What the LLM sees without Skyflow" \
    "curl -s $DEMO_HOST/demo/raw -H 'content-type: application/json' -d '$PROMPT' | jq -r '.json.messages[-1].content'" \
    "$c_purple" "Prompt (raw)" "echo: calling OpenAI via Kong with echo back"

  # echo: calling OpenAI via Kong + Skyflow with echo back
  step "2 · What the LLM sees with Skyflow" \
    "curl -s $DEMO_HOST/demo/deid -H 'content-type: application/json' -d '$PROMPT' | jq -r '.json.messages[-1].content'" \
    "$c_purple" "Prompt (de-identified)" "echo: calling OpenAI via Kong + Skyflow with echo back"

  # e2e: calling OpenAI via Kong + Skyflow with real re-identified response
  if [ "${INCLUDE_LIVE:-1}" = "1" ]; then
    step "3 · What the caller gets back — re-identified by Skyflow" \
      "curl -s $DEMO_HOST/ai/chat -H 'content-type: application/json' -d '$PROMPT' | jq -r '.choices[0].message.content'" \
      "$c_purple" "Response (re-identified)" "e2e: calling OpenAI via Kong + Skyflow with real re-identified response"
  fi

  # Two SEPARATE requests, same patient. VAULT_TOKEN is deterministic per value, so
  # "Maria Gonzalez" tokenizes to the IDENTICAL [NAME_...] in both — the stable
  # mapping that lets a multi-turn conversation stay coherent (see demo/act2).
  step "4 · Same patient → same token (referential integrity)" \
    "for p in \"\$RECUR_PROMPT_A\" \"\$RECUR_PROMPT_B\"; do curl -s $DEMO_HOST/demo/deid -H 'content-type: application/json' -d \"\$p\" | jq -r '.json.messages[-1].content'; done" \
    "$c_purple" "De-identified — note the matching token" "deterministic vault tokens across requests"
}
