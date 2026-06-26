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

> **Heads up / honesty:** I authored this from an environment whose egress
> policy blocks `*.api.konghq.com`, so I could **not** test the live Konnect
> handshake or the exact cluster endpoints. The steps below are the standard
> Konnect hybrid flow; the **UI path is authoritative** for the cert + endpoints
> (Konnect generates them for you). File/Lua/YAML here are validated; the
> Konnect-side values you fill in from your account.

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

### 3. Upload the custom plugin to the control plane
Control plane → **Plugins** → **Custom Plugins** → **New**. Upload both files:
- `../../plugin/kong/plugins/skyflow-deidentify/schema.lua`  (it's `require`-free, as Konnect requires)
- `../../plugin/kong/plugins/skyflow-deidentify/handler.lua`

This registers the plugin so the control plane will accept its config. (The
handler also executes on your DP because compose mounts the `plugin/` dir.)

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

## Point at a real Skyflow vault (optional)
In `deck/kong.yaml`, remove `skyflow_base_url_override`, set the real
`vault_id`/`cluster_id`, and set `credentials.api_key` to a Skyflow key with the
Detect de-identify permission; re-sync. (Use a Konnect Vault reference for the
key in anything beyond a throwaway demo.)

## Troubleshooting
| Symptom | Fix |
| --- | --- |
| DP won't connect / TLS errors | Re-check the four `.env` endpoints and that `certs/tls.crt`+`tls.key` are the ones Konnect generated. |
| `deck sync`: "plugin 'skyflow-deidentify' not found" | Do step 3 (upload the custom plugin) before syncing. |
| Plugin not loading on DP | Confirm `KONG_PLUGINS=bundled,skyflow-deidentify` and the `../../plugin` mount; check `docker compose logs kong-dp`. |
| Upstream still sees PII | Check the plugin attached to the route and `profile: openai` matches your payload shape. |
