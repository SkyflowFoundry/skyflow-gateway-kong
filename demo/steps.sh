# Demo steps for the skyflow-kong-poc live demo.
#
# Driven by record-demo.sh from the personal demo-media skill (see demo/README.md).
# Run from the repo root:
#   record-demo --steps demo/steps.sh              # record MP4 + GIF
#   record-demo --steps demo/steps.sh --no-record  # rehearse the curls only
#
# All steps hit the Konnect-hybrid data plane (:8000) backed by the real Skyflow
# vault. INCLUDE_LIVE=0 skips the two real-OpenAI steps (1 and 4).

DEMO_TITLE="Skyflow × Kong — de-identify PII in your LLM traffic"

HOST="${HOST:-localhost:8000}"   # Konnect-hybrid data plane (real Skyflow vault)

# One PII-laden prompt used across the steps.
REC='{"messages":[{"role":"user","content":"Reply to Jane Doe at jane@acme.com, phone 415-555-0132"}]}'
# A realistic task for the live LLM steps.
ASK='{"messages":[{"role":"user","content":"Draft a friendly one-sentence appointment reminder for Jane Doe (jane@acme.com, 415-555-0132)."}]}'

demo() {
  # 1) BEFORE — no gateway protection. /_ai_upstream is the ai-proxy passthrough
  #    with NO de-identify plugin, so the raw PII prompt goes straight to OpenAI.
  if [ "${INCLUDE_LIVE:-1}" = "1" ]; then
    step "Raw: prompts with PII hit AI" \
      "curl -s $HOST/_ai_upstream -H 'content-type: application/json' -d '$ASK' | jq -r '.choices[0].message.content'"
  fi

  # 2) The /demo/deid route de-identifies then echoes the request, so you SEE the
  #    tokenized prompt the model would receive — no raw PII.
  step "De-identified: what the LLM receives" \
    "curl -s $HOST/demo/deid -H 'content-type: application/json' -d '$REC' | jq -r '.json.messages[-1].content'"

  # 3) Skyflow can reverse the tokens on demand. /vault/chat de-identifies, the
  #    mock LLM echoes the tokens back, and re-identify restores the prompt.
  step "Re-identified prompt: prompts can be re-identified on demand" \
    "curl -s $HOST/vault/chat -H 'content-type: application/json' -d '$REC' | jq -r '.choices[0].message.content'"

  # 4) The full flow on real OpenAI: prompt de-identified -> LLM -> response
  #    re-identified by Skyflow. Same useful answer as step 1, PII never exposed.
  if [ "${INCLUDE_LIVE:-1}" = "1" ]; then
    step "Re-identified response: prompt de-identified and sent to LLM, response re-identified by Skyflow" \
      "curl -s $HOST/ai/chat -H 'content-type: application/json' -d '$ASK' | jq -r '.choices[0].message.content'"
  fi
}
