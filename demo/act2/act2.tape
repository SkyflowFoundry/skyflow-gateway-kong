# act2.tape — Act 2: a real coding agent (opencode) reasoning over PHI through the
# Skyflow × Kong gateway. Records the ACTUAL opencode CLI — not a simulation.
#
# Render (needs the :8000 DP up + opencode installed):
#   cd demo/act2 && vhs act2.tape        -> ../../demo-out/act2.{gif,mp4}
# Validate (parse only):
#   cd demo/act2 && vhs validate act2.tape
#
# NOTE: hits real OpenAI via :8000, so the agent's wording varies per render.

Output ../../demo-out/act2.gif
Output ../../demo-out/act2.mp4

Source config.tape                 # shared look (theme, size, font, prompt WaitPattern)
Set WaitTimeout 120s

# ── hidden setup: opencode env + clean screen (off camera) ──────────────────────────
# CI=1 + NO_COLOR force opencode's plain, non-interactive output. Without them VHS's
# terminal answers opencode's capability probes, opencode picks its rich TUI renderer,
# and the turn stalls mid-stream on a query VHS never answers.
Hide
Type "export PS1='$ '" Enter
Type "cd /Users/joe/Code/skyflow-kong-poc/demo/act2" Enter
Type "export PATH=$HOME/.opencode/bin:$PATH" Enter
Type "export OPENCODE_CONFIG=$PWD/opencode.json" Enter
Type "export KONG_AI_BASE_URL=http://localhost:8000/ai/v1" Enter
Type "export OPENAI_API_KEY=sk-dummy-kong-injects-the-real-one" Enter
Type "export CI=1 NO_COLOR=1" Enter
Type "clear" Enter
Show

# ── the whole demo: opencode reads a PHI file and answers (real names, for the dev) ──
Sleep 800ms
Type@35ms "opencode run -m kong/gpt-4o-mini 'Read patient_intake.py and list each patient with their current medications, one line each.'" Enter
Wait                               # fires when the shell prompt ($) returns = opencode done
Sleep 3s
