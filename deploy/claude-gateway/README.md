# Claude Code through the Skyflow gateway

Run the **real Claude Code CLI** through Kong with the `skyflow-deidentify`
plugin in the path: every LLM-bound request is de-identified against a live
Skyflow vault, responses are re-identified on the way back, and the model
provider (OpenAI, via `ai-proxy` with `llm_format: anthropic`) only ever sees
vault tokens. Agents' tool inputs stay tokenized (`reidentify.tool_inputs`
defaults to `tokenized`), so files an agent writes and searches it runs carry
tokens, never raw PII.

```text
Claude Code ──► Kong :8000/claude ── de-identify ──► ai-proxy ──► OpenAI
   (you)   ◄── re-identify ◄─────────────────────────  (sees tokens only)
```

## Prerequisites

- Docker + Docker Compose
- [Claude Code](https://claude.com/claude-code) (`claude --version`)
- A Skyflow vault with Detect, and a **service account** whose role has the
  de-identify **and** re-identify permissions (its credentials JSON, plus the
  vault ID, cluster ID, and account ID)
- An OpenAI API key

## 1. Configure

```bash
cd deploy/claude-gateway

export SKYFLOW_VAULT_ID=...
export SKYFLOW_CLUSTER_ID=...          # https://<cluster_id>.vault.skyflowapis.com
export SKYFLOW_ACCOUNT_ID=...
export SKYFLOW_SA_JSON='{"clientID":"...","keyID":"...","tokenURI":"...","privateKey":"..."}'
export OPENAI_API_KEY=sk-...

./setup.sh                              # writes kong.yaml (gitignored)
```

## 2. Start the gateway

```bash
OPENAI_AUTH_HEADER="Bearer $OPENAI_API_KEY" docker compose up -d
```

## 3. Run Claude Code through it

```bash
ANTHROPIC_BASE_URL=http://localhost:8000/claude \
ANTHROPIC_API_KEY=dummy-kong-injects-the-real-one \
ANTHROPIC_MODEL=gpt-4o-mini \
ANTHROPIC_SMALL_FAST_MODEL=gpt-4o-mini \
CLAUDE_CODE_MAX_OUTPUT_TOKENS=8192 \
claude --model gpt-4o-mini
```

Notes:

- The env prefixes affect **that session only** — other Claude Code sessions
  on the machine keep talking to Anthropic directly.
- `CLAUDE_CODE_MAX_OUTPUT_TOKENS=8192` is required: Claude Code asks for 32k
  completion tokens; gpt-4o-mini caps at 16384.
- The dummy API key is intentional — `ai-proxy` injects the real OpenAI key
  at the gateway, so no LLM credential lives on the client.

Chat normally and mention some PII ("draft a note to Jane Doe at
`jane@acme.com`").

## 4. See the protection working

What any upstream would receive (tokens), via the echo probe:

```bash
curl -s localhost:8000/probe/deid -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user",
       "content":"Jane Doe, jane@acme.com, SSN 123-45-6789"}]}' \
  | jq -r '.json.messages[0].content'
# [NAME_...], [EMAIL_ADDRESS_...], SSN [SSN_...]
```

Per-request detections and caller context (also visible as the Context ID on
Skyflow audit events):

```bash
docker exec skyflow-claude-gateway sh -c 'cat /tmp/skyflow-gateway.json' \
  | jq -c 'select(.skyflow) | {entities: .skyflow.entities_by_type, status: .response.status}'

docker logs skyflow-claude-gateway 2>&1 | grep 'minted SA bearer'
```

Per-caller context: add a header and watch a distinct bearer get minted —
`ANTHROPIC_CUSTOM_HEADERS="X-Demo-User: alice" claude ...` (it lands in the
bearer as `$ctx.caller.user`).

## Cleanup

```bash
docker compose down
```
