# Local db-less harness — reproduce + verify the ai-proxy fix offline

Fully self-contained: db-less Kong + mock Skyflow + **gzip** mock LLM. No Konnect
control plane, no PAT, no real OpenAI key. Proves the de-id → ai-proxy(LLM) →
re-id round-trip and reproduces Kong #14380.

## Run

```bash
docker compose -f deploy/local-dbless/docker-compose.yml up -d --wait

# STS-only: every request needs a caller identity token. This harness leaves
# expected_issuer/expected_audience unset, so an unsigned fixture JWT (alg=none,
# no exp) satisfies the precheck. Not a credential.
JWT=eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJkZW1vLXVzZXIiLCJlbWFpbCI6ImRlbW9AZXhhbXBsZS5jb20iLCJuYW1lIjoiRGVtbyBVc2VyIn0.sig
```

Proxy is on host port **8010** (the Konnect DP demo uses 8000).

## The three routes

```bash
P='{"messages":[{"role":"user","content":"Reply to Jane Doe at jane@acme.com"}]}'

# 1) baseline — de-id -> mock LLM -> re-id, no ai-proxy.  => 200, PII restored
curl -s localhost:8010/vault/chat  -H "authorization: Bearer $JWT" -H 'content-type: application/json' -d "$P" | jq .

# 2) the BUG — de-id + ai-proxy + re-id on ONE route.     => 500
#    {"error":{"message":"no response body found when transforming response"}}
curl -s localhost:8010/broken/chat -H "authorization: Bearer $JWT" -H 'content-type: application/json' -d "$P" | jq .

# 3) the FIX — nested proxy (de-id/re-id front -> ai-proxy route).  => 200, PII restored
curl -s localhost:8010/ai/chat     -H "authorization: Bearer $JWT" -H 'content-type: application/json' -d "$P" | jq .
```

Proof the LLM only ever sees tokens:

```bash
docker logs skyflow-mock-llm-local 2>&1 | grep 'MOCK-LLM RECEIVED'
# MOCK-LLM RECEIVED: Reply to [NAME_aB3xQ] at [EMAIL_ADDRESS_kp2]
```

## Why /broken fails and /ai works

ai-proxy transforms the LLM response in its `header_filter`
(`parse-json-response` → `normalize-json-response`). Re-identify must run in the
`response` phase (it calls Skyflow over a cosocket, which is banned in
`body_filter`). On one route the response-phase rewrite consumes the buffered
body before ai-proxy reads it — but **only when the body is gzip-encoded**, which
real OpenAI always is (this mock LLM gzips too, unlike the older uncompressed
mock). The nested split gives ai-proxy and re-identify separate request cycles.

The mock LLM here gzips on purpose (`gzip on` + ai-proxy sends
`Accept-Encoding: gzip`) so the harness faithfully reproduces the real failure.

## Notes

- db-less declarative routes default to https-only, so `kong.yaml` sets
  `protocols: ["http","https"]` on each route. Control-plane-synced routes
  (the deck files) don't need this.
- Reload after editing `kong.yaml` or a mock: `docker compose ... restart kong`
  (or `restart mock-llm`).
