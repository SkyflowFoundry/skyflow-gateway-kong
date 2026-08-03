# Developer ergonomics for the skyflow-deidentify Kong plugin.
# See docs/05 (implementation plan) and docs/06 (testing).

PLUGIN := skyflow-deidentify
VERSION := 0.2.0-1

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

lint:
	luacheck plugin spec *.rockspec

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

e2e:
	docker compose up -d
	./scripts/demo.sh   # runs the worked example from docs/03 §3.9
	docker compose down

# Guarded: requires SKYFLOW_VAULT_ID / SKYFLOW_CLUSTER_ID / SKYFLOW_API_KEY.
sandbox-smoke:
	@test -n "$$SKYFLOW_VAULT_ID" || (echo "set SKYFLOW_VAULT_ID/CLUSTER_ID/API_KEY" && exit 1)
	pongo run -- --tags=sandbox

pack:
	luarocks make ./plugin/kong/plugins/$(PLUGIN)/$(PLUGIN)-$(VERSION).rockspec
	luarocks pack $(PLUGIN) $(VERSION)

clean:
	rm -f *.rock
