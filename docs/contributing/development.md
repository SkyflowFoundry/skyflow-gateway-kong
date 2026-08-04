# Development

Repo layout, dependencies, local dev loop, and CI for working on the plugin.
For test strategy see [`testing.md`](testing.md); for the config schema and
lifecycle see [`plugin-spec.md`](plugin-spec.md).

## Repository layout

```text
skyflow-kong-poc/
├── plugin/kong/plugins/skyflow-deidentify/
│   ├── handler.lua      # ALL logic inlined: auth + Skyflow Detect client +
│   │                    #   JSONPath-lite body targeting + de-identify + re-identify
│   ├── schema.lua       # config contract — require-free (Konnect upload constraint)
│   └── *.rockspec       # self-managed / local installs only
├── spec/
│   ├── offline/pure_algorithms_test.lua   # luajit only — no Kong/Docker (make unit-pure)
│   └── skyflow-deidentify/                 # busted/Pongo specs (schema, access, response)
├── deploy/
│   ├── local-dbless/    # offline harness: db-less Kong + mock Skyflow + gzip mock LLM
│   └── konnect-hybrid/  # self-managed data plane on Konnect + deck/ configs
├── docs/
│   ├── using/           # operator/user docs
│   └── contributing/    # these developer docs
├── Makefile             # lint / lint-md / unit-pure / test / e2e / sandbox-smoke / pack
└── .github/workflows/   # markdownlint CI
```

> The logical module decomposition (`auth`/`client`/`body`/`mapping`) in
> [`architecture.md §2.2`](architecture.md#22-module-decomposition) is a *design*
> view. Physically everything is inlined into `handler.lua` and `schema.lua` is
> `require`-free, because Konnect Dedicated Cloud Gateways accept only two
> self-contained files (see [`plugin-spec.md`](plugin-spec.md) and
> [`../using/deployment.md`](../using/deployment.md)). The same two files also
> work on self-managed nodes via the
> [rockspec](../../plugin/kong/plugins/skyflow-deidentify).

## Dependencies

- **Runtime-provided** (not vendored): `cjson`, `resty.http`, `kong.tools.gzip`,
  `lua-resty-lock` — all ship with Kong/OpenResty.
- **No** `lua-resty-jwt`: auth is API key / static bearer token. Service-account
  JWT (RS256, via bundled `resty.openssl`) is a documented follow-up.

## Local dev loop

```bash
make lint          # luacheck the plugin + specs
make lint-md       # markdownlint the docs (FIX=1 to auto-fix)
make unit-pure     # offline pure-algorithm tests (luajit only, no Kong/Docker)
make test          # luacheck + unit-pure + Pongo integration (mock Skyflow, Docker)
make e2e           # docker-compose: Kong + mock Skyflow + echo upstream + demo
make sandbox-smoke # OPTIONAL: against a real Skyflow sandbox (needs SKYFLOW_* creds)
```

`make test` needs only Docker — no Skyflow account — so the functional suite runs
hermetically. For an end-to-end loop that includes `ai-proxy` with zero
Konnect/OpenAI credentials, use [`test/offline-harness/`](../../test/offline-harness).

## CI

- **markdownlint** (`.github/workflows/markdownlint.yml`) runs `make lint-md` on
  PRs and `main`, using the pinned `markdownlint-cli2` version and
  `.markdownlint.jsonc`.
- Follow-ups: wire `make lint` (luacheck) and the Pongo suite into CI, and add a
  Kong-version matrix to catch PDK drift.

## Packaging for Konnect

The two files upload to a control plane (schema for hybrid; schema + handler for
Dedicated Cloud Gateways). Steps and constraints are in
[`../using/deployment.md`](../using/deployment.md).
