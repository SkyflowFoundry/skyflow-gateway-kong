# Developer ergonomics for the skyflow-deidentify Kong plugin.
# See docs/05 (implementation plan) and docs/06 (testing).

PLUGIN := skyflow-deidentify
VERSION := 0.2.0-1

.PHONY: help lint unit-pure test unit integration e2e sandbox-smoke pack clean

help:
	@echo "Targets:"
	@echo "  lint           luacheck the plugin + specs"
	@echo "  unit-pure      offline algorithm tests (luajit only, no Kong/Docker)"
	@echo "  test           full suite (unit-pure + Pongo integration) against the mock Skyflow"
	@echo "  unit           busted unit specs only (no Kong, no network)"
	@echo "  integration    Pongo integration specs (real Kong, mocked Skyflow HTTP)"
	@echo "  e2e            docker-compose: Kong + mock Skyflow + echo upstream; run demo"
	@echo "  sandbox-smoke  OPTIONAL manual smoke vs a real Skyflow sandbox (needs creds)"
	@echo "  pack           luarocks pack the plugin rock"

lint:
	luacheck plugin spec *.rockspec

# No Kong, no Docker: validates the pure path/mask/re-identify algorithms.
unit-pure:
	luajit spec/offline/pure_algorithms_test.lua

# Hermetic: requires only Docker (Pongo). No Skyflow account needed.
test: lint unit-pure
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
