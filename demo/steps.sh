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
  # ── Before vs after: what the model actually receives ──────────────────────
  group "What the LLM sees"

  # RAW (red) — /demo/raw has NO de-identify plugin, so the echo reflects the
  # request exactly as an unprotected upstream would get it: real PII.
  step "Raw: prompts with PII hit AI" \
    "curl -s $HOST/demo/raw -H 'content-type: application/json' -d '$PROMPT' | jq -r '.json.messages[-1].content'" \
    "$c_red"

  # DE-IDENTIFIED (green) — /demo/deid de-identifies first, so the echo shows the
  # tokenized request. Same prompt, no raw PII.
  step "De-identified: what the LLM receives" \
    "curl -s $HOST/demo/deid -H 'content-type: application/json' -d '$PROMPT' | jq -r '.json.messages[-1].content'"

  # ── The actual experience of using the gateway ─────────────────────────────
  # de-identify -> real OpenAI -> re-identify. Skip with INCLUDE_LIVE=0.
  if [ "${INCLUDE_LIVE:-1}" = "1" ]; then
    group "Using the gateway — de-identify + re-identify"
    step "Re-identified response: prompt de-identified and sent to LLM, response re-identified by Skyflow" \
      "curl -s $HOST/ai/chat -H 'content-type: application/json' -d '$PROMPT' | jq -r '.choices[0].message.content'"
  fi
}
