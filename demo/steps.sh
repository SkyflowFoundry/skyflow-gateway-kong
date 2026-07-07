# Demo steps for the skyflow-kong-poc live demo.
#
# Driven by record-demo.sh from the personal demo-media skill (see demo/README.md).
# Run from the repo root:
#   record-demo.sh --steps demo/steps.sh              # record MP4 + GIF
#   record-demo.sh --steps demo/steps.sh --no-record  # rehearse the curls only
#
# Prereq: the demo stacks are up (deploy/local-dbless on :8010, Konnect-hybrid
# DP on :8000). INCLUDE_LIVE=0 skips the real-OpenAI step for a fully offline take.

DEMO_TITLE="Skyflow × Kong — protect PII in your LLM traffic"

HOST_LOCAL="${HOST_LOCAL:-localhost:8010}"   # local-dbless proxy (offline mocks)
HOST_DP="${HOST_DP:-localhost:8000}"         # Konnect-hybrid data plane (real OpenAI)

# A realistic, PII-bearing request.
ASK='{"messages":[{"role":"user","content":"Draft a friendly one-sentence appointment reminder for Jane Doe (jane@acme.com, 415-555-0132)."}]}'
# A record whose details must survive the round-trip exactly.
REC='{"messages":[{"role":"user","content":"Customer on file: Jane Doe, jane@acme.com, 415-555-0132."}]}'

demo() {
  # Hero — a real LLM answers a prompt full of PII. OpenAI only ever receives
  # vault tokens; the caller gets a normal, useful answer with real details restored.
  if [ "${INCLUDE_LIVE:-1}" = "1" ]; then
    step "Live on real OpenAI — sensitive prompt in, useful answer out (PII never leaves the gateway)" \
      "curl -s $HOST_DP/ai/chat -H 'content-type: application/json' -d '$ASK' | jq -r '.choices[0].message.content'"
  fi

  # Guarantee — deterministic round-trip: what goes in comes back re-identified,
  # even though the model only processed tokens. No external dependency.
  step "Exact round-trip — PII de-identified to the model, restored for the caller" \
    "curl -s $HOST_LOCAL/vault/chat -H 'content-type: application/json' -d '$REC' | jq -r '.choices[0].message.content'"
}
