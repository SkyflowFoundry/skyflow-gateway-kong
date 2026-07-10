# Act 2 steps for record-demo: a real coding agent (opencode) through the gateway.
#
# Run from the repo root:
#   record-demo --steps demo/act2/steps.sh
#
# record-demo SOURCES this file and calls demo(); each step() runs one on-camera
# command via `eval`. That means:
#   * $0 here is record-demo, NOT this file -> derive paths from BASH_SOURCE.
#   * the command runs in the recorder's shell (cwd = repo root), so opencode's
#     env (PATH, config, keys) is set INLINE and paths are absolute.
# (This is why you can't point --steps at run.sh: run.sh is a standalone script,
#  not a demo()-defining steps file, and sourcing it breaks $0/$PWD.)

DEMO_TITLE="Skyflow × Kong — coding agent through the gateway"

# Absolute path to this dir, correct even though record-demo sourced us.
A2="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Highlight the patient PII red in the agent's answer (it's re-identified for the
# developer — proof the dev sees real data while OpenAI only ever saw tokens).
HL_SENSITIVE="Maria Gonzalez|David Okafor|Elena Gonzalez|Grace Okafor|Alan Reyes|Sarah Lin|Mercy General Hospital|metformin|lisinopril|albuterol|atorvastatin|88213-A|77120-B"

# opencode installs to ~/.opencode/bin; config + PHI fixture live in this dir.
# Read-only tools are enforced in opencode.json, so the agent never edits the repo.
demo() {
  step "1 · Coding agent reads a PHI file — OpenAI sees only tokens" \
    "cd $A2 && PATH=\"\$HOME/.opencode/bin:\$PATH\" OPENCODE_CONFIG=$A2/opencode.json KONG_AI_BASE_URL=http://localhost:8000/ai/v1 OPENAI_API_KEY=sk-dummy opencode run -m kong/gpt-4o-mini 'Read patient_intake.py and summarize each patient and their current medications.'" \
    "$c_purple" "Agent answer — re-identified for the developer" "opencode → Kong + Skyflow → real OpenAI (tokens only)"
}
