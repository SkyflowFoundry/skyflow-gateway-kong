# Demo steps for the skyflow-kong-poc live demo.
#
# Driven by record-demo.sh from the `demo-media` skill (see demo/README.md).
# Run from the repo root:
#   record-demo.sh --steps demo/steps.sh              # record MP4 + GIF
#   record-demo.sh --steps demo/steps.sh --no-record  # rehearse the curls only
#
# Prereq: the demo stacks are up (deploy/local-dbless on :8010, Konnect-hybrid
# DP on :8000). INCLUDE_LIVE=0 skips the real-OpenAI step to keep it offline.

DEMO_TITLE="Skyflow × Kong — de-identify → LLM → re-identify"

HOST_LOCAL="${HOST_LOCAL:-localhost:8010}"   # local-dbless proxy (offline mocks)
HOST_DP="${HOST_DP:-localhost:8000}"         # Konnect-hybrid data plane (real OpenAI)
PAYLOAD='{"messages":[{"role":"user","content":"Reply to Jane Doe at jane@acme.com, phone 415-555-0132"}]}'

demo() {
  step "1/3  Offline round-trip (mock LLM) — PII out as tokens, back restored" \
    "curl -s $HOST_LOCAL/vault/chat -H 'content-type: application/json' -d '$PAYLOAD' | jq '.choices[0].message.content'"

  step "2/3  The Kong #14380 pitfall — de-id + ai-proxy on ONE route 500s" \
    "curl -s -w '\nHTTP %{http_code}\n' $HOST_LOCAL/broken/chat -H 'content-type: application/json' -d '$PAYLOAD'"

  # Live step hits REAL OpenAI. Skip with INCLUDE_LIVE=0 to keep the capture
  # fully mock/offline (nothing real to redact).
  if [ "${INCLUDE_LIVE:-1}" = "1" ]; then
    step "3/3  Live on Konnect CP + real OpenAI (nested-proxy fix)" \
      "curl -s $HOST_DP/ai/chat -H 'content-type: application/json' -d '$PAYLOAD' | jq '.choices[0].message.content'"
  fi
}
