# Demo steps for the skyflow-kong-poc live demo.
#
# Driven by record-demo.sh from the personal demo-media skill (see demo/README.md).
# Run from the repo root:
#   record-demo --steps demo/steps.sh              # record MP4 + GIF
#   record-demo --steps demo/steps.sh --no-record  # rehearse the curls only
#
# All steps hit the Konnect-hybrid data plane (:8000) backed by the real Skyflow
# vault, and use the SAME prompt — only the route changes. INCLUDE_LIVE=0 skips
# the real-OpenAI step.

DEMO_TITLE="Skyflow × Kong — de-identify PII in your LLM traffic"

HOST="${HOST:-localhost:8000}"   # Konnect-hybrid data plane (real Skyflow vault)

# One PII-laden prompt, reused for every step.
PROMPT='{"messages":[{"role":"user","content":"Draft a friendly one-sentence appointment reminder for Jane Doe (jane@acme.com, 415-555-0132)."}]}'

demo() {
  # echo: calling OpenAI via Kong with echo back
  step "What the LLM sees without Skyflow" \
    "curl -s $HOST/demo/raw -H 'content-type: application/json' -d '$PROMPT' | jq -r '.json.messages[-1].content'" \
    "$c_red" "Prompt" "echo: calling OpenAI via Kong with echo back"

  # echo: calling OpenAI via Kong + Skyflow with echo back
  step "What the LLM sees with Skyflow" \
    "curl -s $HOST/demo/deid -H 'content-type: application/json' -d '$PROMPT' | jq -r '.json.messages[-1].content'" \
    "$c_green" "Prompt" "echo: calling OpenAI via Kong + Skyflow with echo back"

  # e2e: calling OpenAI via Kong + Skyflow with real re-identified response
  if [ "${INCLUDE_LIVE:-1}" = "1" ]; then
    step "What the caller gets back — re-identified by Skyflow" \
      "curl -s $HOST/ai/chat -H 'content-type: application/json' -d '$PROMPT' | jq -r '.choices[0].message.content'" \
      "$c_green" "Response" "e2e: calling OpenAI via Kong + Skyflow with real re-identified response"
  fi
}
