# Act 2 — a real coding agent through the gateway

Act 1 (the `steps.sh` curls) proves the mechanism. Act 2 shows the **use case**: a
real coding-agent CLI — [opencode](https://opencode.ai) — pointed at the gateway's
OpenAI-compatible endpoint, reasoning over a file full of PHI, while OpenAI never
sees a single real value.

```
opencode  ──▶  http://localhost:8000/ai/v1   ──▶  Kong (skyflow-deidentify)  ──▶  OpenAI
  reads         (OpenAI-compatible route)          de-id request / re-id response      sees only [TOKEN]s
patient_intake.py
```

## Why this is the strong version of the demo

- **Real tool, zero code.** opencode speaks the OpenAI Chat Completions wire format.
  Point its `baseURL` at `http://localhost:8000/ai/v1` and it just works — the same
  de-id/re-id path Act 1 proves. Nothing about the agent is Skyflow-aware.
- **The agent never holds the OpenAI key.** It sends a dummy key; Kong's `ai-proxy`
  injects the real one upstream. Secret stays at the gateway.
- **Deterministic tokens = the model stays coherent.** `patient_intake.py` has two
  patients. Every time "Maria Gonzalez" appears — in the file, and across both turns
  of the conversation — Skyflow returns the **same** `[NAME_xjv74g]` token (VAULT_TOKEN
  is deterministic per value). So the model can keep Maria and David straight and
  answer follow-ups correctly, even though it only ever saw opaque tokens. That's
  referential integrity maintaining inference quality — shown, not told.

## Run it

1. **Install opencode** (one-time):

   ```bash
   curl -fsSL https://opencode.ai/install | bash
   ```

2. **Bring up the gateway.** Real run uses the Konnect DP on `:8000` with
   `real-vault.yaml` synced (real vault + real OpenAI — see the repo README). For a
   plumbing-only rehearsal, use local-dbless on `:8010` (mock LLM just echoes).
3. **Go:**

   ```bash
   ./demo/act2/run.sh              # real: :8000 -> real OpenAI
   REHEARSE=1 ./demo/act2/run.sh   # plumbing only: :8010 -> mock LLM
   ```

`run.sh` sets `OPENCODE_CONFIG` to [opencode.json](opencode.json), a dummy
`OPENAI_API_KEY`, and `KONG_AI_BASE_URL`, then runs two turns of `opencode run`.

## Record it (VHS)

The canonical recording is a **VHS** tape — [`act2.tape`](act2.tape) — that drives the
**real** `opencode` CLI (not a simulation) and re-renders on demand:

```bash
cd demo/act2 && vhs act2.tape      # -> ../../demo-out/act2.{gif,mp4}
```

Prereqs: `brew install vhs` (pulls in `ttyd` + `ffmpeg`), the JetBrains Mono font,
`opencode` installed, and the `:8000` DP up (real vault + real OpenAI). The tape sets
opencode's env in a hidden setup block, so no wrapper is needed;
[`config.tape`](config.tape) holds the shared look.

It's deliberately minimal: one `opencode run` reasoning over `patient_intake.py`, and
the answer — with **real** re-identified names — while OpenAI only ever saw tokens (see
[Prove OpenAI only saw tokens](#prove-openai-only-saw-tokens) below to show that half).

Two things that bite:

- **`CI=1 NO_COLOR=1` is load-bearing.** Without it, VHS's terminal answers opencode's
  capability probes, opencode switches to its rich TUI renderer, then blocks on a
  terminal query VHS never answers and the turn **stalls mid-stream**. Those env vars
  force opencode's plain, non-interactive output (streams clean, finishes in ~15s).
- **Not byte-identical.** The render hits real OpenAI, so the agent's wording varies per
  run. The mechanism reproduces; keep the render you like.

The older `record-demo` path (screen-capturing `run.sh`-style steps via
[`steps.sh`](steps.sh)) still works, but VHS is now the recommended way. `run.sh`
remains for running Act 2 directly.

## Prove OpenAI only saw tokens

While it runs (or after), confirm the gateway de-identified the outbound request:

```bash
docker logs skyflow-kong-dp 2>&1 | grep -i deidentif   # the DP you pointed at
```

Or hit the re-id-**off** proof route with the same content to see the tokenized body
the model receives:

```bash
curl -s localhost:8000/demo/deid -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"Patient Maria Gonzalez, MRN 88213-A, on metformin 500mg twice daily."}]}' \
  | jq -r '.json.messages[-1].content'
# -> Patient [NAME_xjv74g], MRN [HEALTHCARE_NUMBER_m3k1c], on [DRUG_d1cc4] [DOSE_e1f30].
```

## Files

| File | Purpose |
| --- | --- |
| [`act2.tape`](act2.tape) | **VHS recording script** — drives the real `opencode` CLI, emits `../../demo-out/act2.{gif,mp4}`. |
| [`config.tape`](config.tape) | Shared VHS look (theme, size, font, prompt `WaitPattern`) — `Source`d by `act2.tape`. |
| [`opencode.json`](opencode.json) | Registers a `kong` provider → the OpenAI-compatible gateway route. |
| [`patient_intake.py`](patient_intake.py) | The PHI-laden file the agent reads and reasons over. |
| [`run.sh`](run.sh) | Headless two-turn driver for running Act 2 directly. |
| [`steps.sh`](steps.sh) | Legacy `record-demo` steps file (superseded by `act2.tape`). |

## What it took to run a real agent (the non-obvious part)

A `curl` demo works out of the box. A real coding agent does **not** — it streams,
it uses tools, and it sends tens of KB of scaffolding. Making opencode work end to
end surfaced five real gaps between "de-identify a JSON body" and "de-identify agent
traffic". All are fixed; each is worth understanding.

| # | Symptom | Root cause | Fix |
| --- | --- | --- | --- |
| 1 | `request blocked: body unavailable` (422) | Agent bodies (big system prompt + tool schemas, ~40 KB) exceed nginx's in-memory buffer, so it spools them to a temp file and `kong.request.get_raw_body()` returns `nil`. Small curls stay in memory. | Handler reads the spooled file (`ngx.req.get_body_file()`) when `get_raw_body()` is `nil`. Plus `KONG_NGINX_HTTP_CLIENT_BODY_BUFFER_SIZE=16m` (compose) so it usually stays in memory. |
| 2 | `request body doesn't contain valid inputs` (502) | Same big body, but on the internal route where **ai-proxy** reads it. ai-proxy's default `max_request_body_size` (~8 KB) rejects it. | `max_request_body_size: 16777216` on the ai-proxy plugin (`real-vault.yaml`) + the nginx buffer bump above. |
| 3 | Tokens leak unrestored; client hangs | The client sends `stream: true`. Re-identification **must buffer** the whole response, but a vault token (`[NAME_xjv74g]`) gets split across SSE chunks (`"["`, `"NAME"`, …) and can't be matched. | Handler forces `stream:false` upstream, re-identifies the full JSON, then **re-emits it as SSE** (`completion_to_sse`) so the client still gets an event-stream. Gated on the client having asked to stream. |
| 4 | Agent reads the wrong path, auto-rejects | opencode's system prompt carries the cwd `/Users/joe/…`; Skyflow tokenizes `joe` as a NAME. The model echoes the token in a tool_call path, and re-id only covered message **content**, not `tool_calls[].function.arguments`. | Handler re-identifies tool_call arguments too. (Alternatives considered: surname-only entities — leaks first names; skip the system prompt — needs role-targeting.) |
| 5 | `skyflow de-identify failed: status 400` → 502 retry loop (looks like a hang) | Agent turns include messages with **empty** `content: ""` (an assistant turn that only made tool calls). Skyflow Detect 400s on empty text. | Handler skips empty-string spans in both the de-id and re-id loops. |

All five live in `plugin/kong/plugins/skyflow-deidentify/handler.lua`. They are gated
so non-agent traffic (the Act 1 curls, the existing specs) is unaffected. **These
changes are picked up on the local hybrid DP via `docker exec skyflow-kong-dp kong
reload` (the plugin dir is mounted). For a Konnect deployment using the *uploaded*
custom plugin, re-upload the updated handler.**

The buffer-to-re-identify trade also means the client gets the answer **all at once**
rather than token-by-token — an acceptable price for never leaking PII, and invisible
in `run` mode.

## opencode config gotchas

- **Read-only tools (recording safety).** `opencode.json` disables `write`, `edit`,
  `patch`, `bash`, `webfetch`, and `task`. Without this, an open-ended prompt makes
  the agent **edit the fixture**, spawn sub-agents (which hit an opencode `task`
  bug — `Expected a string starting with "ses"`) and chase WebFetch — noisy on
  camera and it mutates the repo. Locked to read/glob/grep, the agent just reasons
  over the PHI. Keep the `run.sh` prompts read-only to match.
- **Output limit.** opencode defaults `max_tokens` to 32000; gpt-4o-mini caps at 16384
  → `400 max_tokens is too large`. `opencode.json` pins `limit.output: 16384`.
- **PATH.** The installer puts `opencode` in `~/.opencode/bin`, not always on PATH.
  `run.sh` adds it.
- **`{env:...}` interpolation** in `opencode.json` needs the env vars set — `run.sh`
  does it. Running `opencode` directly? Export `KONG_AI_BASE_URL` + `OPENAI_API_KEY`.
- **Why not Codex.** Codex CLI dropped `wire_api=chat` (Feb 2026) and speaks only the
  Responses API — needs a Kong `llm/v1/responses` route **and** different json_paths
  (Responses body is `input[]`/`output[].content[].text`). opencode avoids all that.

## Operational gotchas (the gateway)

- **DP config changes need a restart, not `kong reload`** for route changes, and the
  Konnect DP can serve **stale** config if its CP link is flapping
  (`did not receive ping frame`). If a synced change doesn't show live:
  `docker restart skyflow-kong-dp` (or `docker compose up -d` to also pick up
  compose-env changes like the buffer size). Plugin *code* (handler.lua) reloads with
  `docker exec skyflow-kong-dp kong reload`.
