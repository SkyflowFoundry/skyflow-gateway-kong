# Konnect Hybrid demo — run the plugin on a self-managed data plane

This gets `skyflow-deidentify` running on a **self-managed data plane** that you
drive from the **Konnect UI** — the way to demo a custom plugin "on Konnect"
without paying for Dedicated Cloud Gateways (which is the only *fully-hosted*
tier that runs custom plugins). The serverless gateway can't run custom plugins
at all, so this is the path.

```
            your laptop / VM                              Konnect (cloud)
  ┌───────────────────────────────────┐          ┌───────────────────────────┐
  │ docker compose:                    │  mTLS    │  Control Plane            │
  │   kong-dp ──── runs the plugin ────┼─────────▶│  (config, UI, analytics)  │
  │   mock-skyflow (Detect API)        │  cluster │  + uploaded plugin schema │
  │   echo (upstream)                  │          └───────────────────────────┘
  └───────────────────────────────────┘
        ▲ demo traffic :8000
```

> **Verified working.** This flow has been run end-to-end against a live Konnect
> control plane and a real Skyflow vault + real OpenAI: the DP connects, `deck
> gateway sync` applies, and `/ai/chat` round-trips (de-id → `ai-proxy` → LLM →
> re-id). The **Konnect UI is authoritative** for the cert + cluster endpoints —
> it generates them for your account; fill those into `certs/` and `.env`.

## Prerequisites

- Docker + Docker Compose
- [`deck`](https://docs.konghq.com/deck/) (for the Service/Route/plugin config)
- Your Konnect PAT in the shell: `export KONNECT_PAT=kpat_...`

## Steps

### 1. Create a hybrid control plane

Konnect → **Gateway Manager** → **New control plane** → **Self-Managed Hybrid**.
Name it `skyflow-hybrid`.

### 2. Add a data plane node (gets you certs + endpoints)

In the control plane → **Data plane nodes** → **New data plane node** →
**Docker**. Konnect generates a **certificate + key** and shows a `docker run`
with the **control-plane** and **telemetry** endpoints.

- Save the cert/key as `certs/tls.crt` and `certs/tls.key` here.
- `cp .env.example .env` and copy the four endpoint values from that command
  into `.env` (the `cp0`/`tp0` hostnames and `:443`).

### 3. Register the custom plugin schema on the control plane

Control plane → **Plugins** → **Custom Plugins** → **New**. Upload **only the
schema**:

- `../../plugin/kong/plugins/skyflow-deidentify/schema.lua`  (it's `require`-free, as Konnect requires)

That is all Konnect needs in **hybrid** mode — the schema lets the control plane
validate the plugin's config. **There is no `handler.lua` upload here**: in
hybrid, the handler runs on *your* data plane, delivered by the `../../plugin`
volume mount in `docker-compose.yml` (plus `KONG_PLUGINS=bundled,skyflow-deidentify`).

> **How does re-identify run after ai-proxy?** Not on the same route — that hits
> Kong #14380 (ai-proxy 500s "no response body found" when a response-phase
> plugin rewrites its gzip-encoded body). Instead the `/ai/chat` config uses a
> **nested proxy**: a front route runs `skyflow-deidentify` (de-id + re-id) and
> its upstream is an internal `/_ai_upstream` route that runs ai-proxy alone.
> Two routes = two independent buffered cycles. One plugin does both halves,
> exactly like `/vault/chat`. See `deck/real-vault.yaml` and, for an offline
> reproduction + verification, `deploy/local-dbless/`.

Uploading the handler to Konnect only applies to **Dedicated Cloud Gateways**,
where Kong runs the data plane for you.

> Registering the schema just makes `skyflow-deidentify` a *known* plugin.
> Attaching it to a route with settings (the "configuration") happens in step 5
> via `deck sync` — that is separate, and not a prerequisite for this step.

### 4. Start the data plane + demo services

```bash
cd deploy/konnect-hybrid
docker compose up -d
docker compose logs -f kong-dp     # wait for "started" / no cluster errors
```

In Konnect, the data plane node should flip to **Connected**.

### 5. Push the Service/Route/plugin config

```bash
deck gateway sync \
  --konnect-token "$KONNECT_PAT" \
  --konnect-control-plane-name "skyflow-hybrid" \
  deck/kong.yaml
```

### 6. Demo it

```bash
curl -s localhost:8000/demo/chat \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Email Jane Doe at jane@acme.com about card 4111111111111111"}]}' | jq .
```

The `echo` upstream reflects **what it received** — you'll see the content the
"LLM" got was tokenized:

```
"Email [NAME_aB3xQ] at [EMAIL_ADDRESS_kp2] about card [CREDIT_CARD_N92QAVa]"
```

The original PII (`Jane Doe`, `jane@acme.com`, the card) never left the data
plane. Flip `dry_run: true` in `deck/kong.yaml` + re-sync to show detections
without altering traffic; toggle `reidentify` to show re-hydration.

### 7. AI Gateway flow — de-identify → `ai-proxy` → real LLM → re-identify

`deck/kong.yaml` (above) uses an echo upstream. To run the full AI Gateway
round-trip through `ai-proxy`, sync one of the AI configs instead — each defines
the nested-proxy routes (`/ai/chat` front + `/_ai_upstream` internal):

- **`deck/real-vault.yaml` — the canonical / default demo config.** Real Skyflow
  vault + real LLM (needs `DECK_SKYFLOW_*` and `DECK_OPENAI_API_KEY`). Defines
  `/vault/chat`, `/ai/chat`, **and `/demo/deid`** — the de-identify-only echo
  route the recorded demo (`../../demo/steps.sh`) uses to *show* the tokenized
  request the upstream receives. **This is the file kept synced to the CP.**
- `deck/ai-gateway.yaml` — mock Skyflow, real LLM (needs `DECK_OPENAI_API_KEY`).
  No `/demo/deid` or `/vault/chat` — a mock alternative, not the demo default.

```bash
export DECK_OPENAI_API_KEY=sk-...
export DECK_SKYFLOW_VAULT_ID=... DECK_SKYFLOW_CLUSTER_ID=... DECK_SKYFLOW_API_KEY=...
deck gateway sync --konnect-token "$KONNECT_PAT" \
  --konnect-control-plane-name skyflow-hybrid \
  deck/real-vault.yaml            # canonical; the demo expects this on the CP

curl -s localhost:8000/ai/chat -H 'content-type: application/json' \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Hi my name is Jane Doe"}]}' | jq .
```

You get a real LLM reply with `Jane Doe` restored, while the provider only ever
saw a token. See the repo root [`README.md`](../../README.md#architecture) for
why the routes are nested, and [`deck/VERIFY-DETECT.md`](deck/VERIFY-DETECT.md)
to confirm the live Detect contract before pointing at a real vault.

> ⚠️ **The control plane is shared and `deck gateway sync` is destructive** — it
> makes the CP match the synced file exactly and deletes anything not in it.
> Syncing `deck/kong.yaml` or `deck/ai-gateway.yaml` removes `real-vault.yaml`'s
> routes (`/vault/chat`, `/ai/chat`, `/demo/deid`) and breaks the demo. Treat
> `deck/real-vault.yaml` as the default; if the demo 404s, re-sync it to restore.

## Point at a real Skyflow vault (optional)

In `deck/kong.yaml`, remove `skyflow_base_url_override`, set the real
`vault_id`/`cluster_id`, and set `credentials.api_key` to a Skyflow key with the
Detect de-identify permission; re-sync. (Use a Konnect Vault reference for the
key in anything beyond a throwaway demo.)

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Bind for 0.0.0.0:8000 failed: port is already allocated` | Something else holds the port. Free it (`lsof -i :8000`, or stop the other container), or set `PROXY_HTTP_PORT`/`PROXY_HTTPS_PORT` in `.env` and re-run. |
| `WARN ... KONNECT_* variable is not set` | You have no `.env` (or it's missing those keys). `cp .env.example .env` and fill the four endpoints from Konnect's "new data plane node" command. Without them the DP can't join the control plane. |
| `cluster_cert: failed loading certificate ...` | The file at the mount (`certs/tls.crt`) is missing/empty or malformed PEM — usually literal `\n` instead of real line breaks (from copying the `-e KONG_CLUSTER_CERT=` value). Re-save clean PEM from Konnect's separate **Certificate**/**Private key** boxes via a quoted heredoc (`cat > certs/tls.crt <<'EOF'`), or `printf '%b' "$VAL" > certs/tls.crt`. Verify: `openssl x509 -in certs/tls.crt -noout -subject`. Then `docker compose up -d`. |
| DP won't connect / TLS errors | Re-check the four `.env` endpoints and that `certs/tls.crt`+`tls.key` are the ones Konnect generated. |
| `deck sync`: "plugin 'skyflow-deidentify' not found" | Do step 3 (upload the custom plugin) before syncing. |
| Plugin not loading on DP | Confirm `KONG_PLUGINS=bundled,skyflow-deidentify` and the `../../plugin` mount; check `docker compose logs kong-dp`. |
| Upstream still sees PII | Check the plugin attached to the route and `profile: openai` matches your payload shape. |
