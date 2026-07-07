# Demo steps for the skyflow-kong-poc live demo.
#
# Driven by record-demo.sh from the personal demo-media skill (see demo/README.md).
# Run from the repo root:
#   record-demo.sh --steps demo/steps.sh              # record MP4 + GIF
#   record-demo.sh --steps demo/steps.sh --no-record  # rehearse the curls only
#
# All three steps hit the Konnect-hybrid data plane (:8000) backed by the real
# Skyflow vault. INCLUDE_LIVE=0 skips the real-OpenAI step.

DEMO_TITLE="Skyflow × Kong — PII never leaves the gateway"

HOST="${HOST:-localhost:8000}"   # Konnect-hybrid data plane (real Skyflow vault)

# One request full of PII, used across the steps.
REC='{"messages":[{"role":"user","content":"Reply to Jane Doe at jane@acme.com, phone 415-555-0132"}]}'
# A realistic task for the live LLM step.
ASK='{"messages":[{"role":"user","content":"Draft a friendly one-sentence appointment reminder for Jane Doe (jane@acme.com, 415-555-0132)."}]}'

demo() {
  # PROOF — the /demo/deid route de-identifies then echoes the request back, so
  # you SEE exactly what the upstream received: tokens, no raw PII.
  step "What your LLM vendor actually receives — de-identified, tokens only" \
    "curl -s $HOST/demo/deid -H 'content-type: application/json' -d '$REC' | jq -r '.json.messages[-1].content'"

  # ROUND-TRIP — same request through de-id -> LLM -> re-id: the caller gets the
  # real details back, though the model only ever processed tokens.
  step "What your caller gets back — same request, PII restored" \
    "curl -s $HOST/vault/chat -H 'content-type: application/json' -d '$REC' | jq -r '.choices[0].message.content'"

  # LIVE — end-to-end against real OpenAI. Skip with INCLUDE_LIVE=0.
  if [ "${INCLUDE_LIVE:-1}" = "1" ]; then
    step "End-to-end on real OpenAI — a useful answer, PII protected in transit" \
      "curl -s $HOST/ai/chat -H 'content-type: application/json' -d '$ASK' | jq -r '.choices[0].message.content'"
  fi
}
