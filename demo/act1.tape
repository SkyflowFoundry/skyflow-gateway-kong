# act1.tape — Act 1: the mechanism, on camera. One PHI-dense healthcare prompt run
# three ways through the Skyflow × Kong gateway — raw vs de-identified vs the
# re-identified answer — so the contrast is visible in one take. Real curls, real
# vault, real OpenAI on :8000.
#
# Render (needs the :8000 DP up):
#   cd demo && vhs act1.tape             -> ../demo-out/act1.{gif,mp4}
# Validate (parse only):
#   cd demo && vhs validate act1.tape
#
# NOTE: step 3 hits real OpenAI, so the answer's wording varies per render.

Output ../demo-out/act1.gif
Output ../demo-out/act1.mp4

Source act2/config.tape            # shared look (theme, size, font, prompt WaitPattern)
Set WaitTimeout 60s                # step 3 = de-id + real OpenAI + re-id round-trips
Set Shell bash                     # NOT zsh: the scenario sets $PROMPT, and in zsh PROMPT *is* $PS1 — sourcing it would clobber the prompt (and break the bare-Wait). bash treats PROMPT as an ordinary var.

# ── hidden setup: host + scenario content + clean screen (off camera) ────────────────
# Sourcing the scenario gives us $PROMPT, so the visible curls stay short (-d "$PROMPT")
# instead of a screenful of inline JSON. Same content layer steps.sh uses.
Hide
Type "export PS1='$ '" Enter
Type "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH" Enter    # VHS's shell skips ~/.zshrc, so jq isn't on PATH otherwise
Type "cd /Users/joe/Code/skyflow-kong-poc/demo" Enter
Type "export DEMO_HOST=localhost:8000" Enter
Type ". scenarios/healthcare.sh" Enter
Type "clear" Enter
Show

# ── beat 1: what the model would see WITHOUT Skyflow — the raw PHI ───────────────────
Sleep 800ms
Type "# without Skyflow × Kong: the raw PHI the model would receive" Enter
Type@30ms `curl -s $DEMO_HOST/demo/raw -H 'content-type: application/json' -d "$PROMPT" | jq -r '.json.messages[-1].content'` Enter
Wait
Sleep 1500ms

# ── beat 2: what the model sees WITH Skyflow — same prompt, de-identified to tokens ──
Enter                              # blank line separates this beat from the one above
Type "# with Skyflow × Kong: same prompt, de-identified to tokens" Enter
Type@30ms `curl -s $DEMO_HOST/demo/deid -H 'content-type: application/json' -d "$PROMPT" | jq -r '.json.messages[-1].content'` Enter
Wait
Sleep 1500ms

# ── beat 3: the answer the caller gets back, re-identified (OpenAI only saw tokens) ──
Enter
Type "# the caller's answer, re-identified — OpenAI only ever saw tokens" Enter
Type@30ms `curl -s $DEMO_HOST/ai/chat -H 'content-type: application/json' -d "$PROMPT" | jq -r '.choices[0].message.content'` Enter
Wait
Sleep 3s
