# Developer ergonomics for the skyflow-deidentify Kong plugin.
# See docs/05 (implementation plan) and docs/06 (testing).

PLUGIN := skyflow-deidentify
# Must match `version` in the rockspec, or `make pack` builds a path to a file
# that does not exist. It said 0.2.0-1 while the rockspec had moved to 0.3.0-1.
VERSION := 0.3.0-1
ROCKSPEC := plugin/kong/plugins/$(PLUGIN)/$(PLUGIN)-$(VERSION).rockspec

.PHONY: help lint lint-md unit-pure globals test unit integration e2e sandbox-smoke pack clean

help:
	@echo "Targets:"
	@echo "  lint           luacheck the plugin + specs"
	@echo "  lint-md        markdownlint the docs (needs node/npx)"
	@echo "  unit-pure      offline algorithm tests (Docker only, no Kong config needed)"
	@echo "  globals        scan the handler for undefined/sandbox-forbidden globals"
	@echo "  test           full suite (unit-pure + Pongo integration) against the mock Skyflow"
	@echo "  unit           busted unit specs only (no Kong, no network)"
	@echo "  integration    Pongo integration specs (real Kong, mocked Skyflow HTTP)"
	@echo "  e2e            docker-compose: Kong + mock Skyflow + echo upstream; run demo"
	@echo "  sandbox-smoke  OPTIONAL manual smoke vs a real Skyflow sandbox (needs creds)"
	@echo "  pack           luarocks pack the plugin rock"

# `*.rockspec` used to be globbed at the repo ROOT, where there is none -- the
# pattern reached luacheck unexpanded and it failed on a literal "*.rockspec".
lint:
	luacheck plugin spec $(ROCKSPEC)

# Markdown lint (config in .markdownlint.jsonc). `make lint-md FIX=1` to auto-fix.
# Version pinned so local and CI (.github/workflows/markdownlint.yml) match.
MDLINT_VERSION := 0.23.0
lint-md:
	npx --yes markdownlint-cli2@$(MDLINT_VERSION) $(if $(FIX),--fix) "**/*.md"

# Validates the pure path/mask/re-identify algorithms.
#
# Runs under `resty` inside the SAME Kong image the data plane runs -- NOT bare
# luajit, which this target used to invoke. Two reasons that was wrong: luajit is
# absent on most machines, and on a box that HAS it without lua-cjson the codec
# tests assert against a stub and report five spurious failures. The runtime has
# to match production or the suite is testing a different library set.
# Keep in lockstep with .github/workflows/test.yml.
KONG_IMAGE := kong/kong-gateway:3.15.0.2
unit-pure:
	docker run --rm -v "$(PWD):/w" -w /w --entrypoint resty $(KONG_IMAGE) \
	  spec/offline/pure_algorithms_test.lua

# The outage guard: a called-but-never-defined local resolves as a nil global and
# kills every request. Also rejects globals the streamed-plugin sandbox withholds.
globals:
	docker run --rm -v "$(PWD):/w" -w /w --entrypoint sh $(KONG_IMAGE) \
	  -c 'bash spec/offline/no_undefined_globals.sh'

# Hermetic: requires only Docker (Pongo). No Skyflow account needed.
test: lint unit-pure globals
	pongo run

unit:
	busted --config=.busted spec/skyflow-deidentify

integration:
	pongo run -- spec/skyflow-deidentify/02-access_spec.lua spec/skyflow-deidentify/03-response_spec.lua

# There is no compose file at the repo root and scripts/demo.sh does not exist,
# so this target could never have run. The offline harness lives in
# deploy/local-dbless; drive that, and assert the de-identified result rather
# than only bringing the stack up.
COMPOSE := docker compose -f deploy/local-dbless/docker-compose.yml
# The plugin is STS-only, so every request needs a caller identity token. The
# harness leaves expected_issuer/expected_audience unset, so an unsigned fixture
# JWT with no `exp` satisfies the precheck -- no IdP, no keys. Header
# {"alg":"none"}, payload {"sub":"demo-user",...}. Not a credential.
DEMO_JWT := eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJkZW1vLXVzZXIiLCJlbWFpbCI6ImRlbW9AZXhhbXBsZS5jb20iLCJuYW1lIjoiRGVtbyBVc2VyIn0.sig
e2e:
	$(COMPOSE) up -d --wait
	@out=$$(curl -s localhost:8010/ai/chat -H 'content-type: application/json' \
	  -H 'authorization: Bearer $(DEMO_JWT)' \
	  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Reply to Jane Doe at jane@acme.com"}]}'); \
	echo "client sees: $$out"; \
	sent=$$(docker logs skyflow-mock-llm-local 2>&1 | grep -oE 'MOCK-LLM RECEIVED.*' | tail -1); \
	echo "upstream saw: $$sent"; \
	fail=0; \
	echo "$$sent" | grep -q 'NAME_' || { echo "FAIL: the name reached the upstream in the clear"; fail=1; }; \
	echo "$$out"  | grep -q 'Jane Doe' || { echo "FAIL: the client did not get a re-identified response"; fail=1; }; \
	$(COMPOSE) down >/dev/null 2>&1; \
	[ $$fail -eq 0 ] && echo "ok: tokenized on egress, restored to the client" || exit 1

# Guarded: requires SKYFLOW_VAULT_ID / SKYFLOW_CLUSTER_ID /
# SKYFLOW_SERVICE_ACCOUNT_ID. There is no API key: the plugin is STS-only.
sandbox-smoke:
	@test -n "$$SKYFLOW_VAULT_ID" || (echo "set SKYFLOW_VAULT_ID / SKYFLOW_CLUSTER_ID / SKYFLOW_SERVICE_ACCOUNT_ID" && exit 1)
	pongo run -- --tags=sandbox

pack:
	luarocks make ./plugin/kong/plugins/$(PLUGIN)/$(PLUGIN)-$(VERSION).rockspec
	luarocks pack $(PLUGIN) $(VERSION)

clean:
	rm -f *.rock
