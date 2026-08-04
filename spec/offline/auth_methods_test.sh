#!/bin/sh
# Auth-method enum: does the SCHEMA enforce the ctx asymmetry?
#
# Validates through `kong config parse`, i.e. Kong's REAL schema engine in a real
# Kong environment. kong.db.schema cannot be required standalone under `resty`
# (it pulls kong.constants, which pulls enterprise files absent from the module
# path), and a hand-rolled walk of the schema table would prove nothing about
# what Kong actually accepts at config time.
#
# The property under test: `ctx` is configurable ONLY under jwt_credential.
# Under sts, Skyflow ignores caller-supplied context; under bearer_token there is
# no assertion to carry it. Silently accepting those fields would let an operator
# ship a vault policy keyed on an attribute that never arrives -- a privacy
# control that reads as configured but is not enforced.
set -u
IMAGE="${KONG_IMAGE:-kong/kong-gateway:3.15.0.2}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

# $1 = description, $2 = expect (accept|reject), $3 = credentials YAML block
case_check() {
  desc="$1"; expect="$2"; creds="$3"
  cat > "$WORK/kong.yaml" <<YAML
_format_version: "3.0"
services:
  - name: s
    url: http://127.0.0.1:8000/_x
    routes:
      - name: r
        paths: ["/x"]
    plugins:
      - name: skyflow-ai-data-control
        config:
          vault_id: v
          cluster_id: c
$(printf '%s\n' "$creds")
YAML
  if docker run --rm -v "$PWD:/w" -v "$WORK:/cfg" -w /w \
       -e KONG_DATABASE=off -e KONG_PLUGINS=bundled,skyflow-ai-data-control \
       -e KONG_LUA_PACKAGE_PATH='/w/plugin/?.lua;;' \
       --entrypoint kong "$IMAGE" config parse /cfg/kong.yaml >"$WORK/out" 2>&1
  then got=accept; else got=reject; fi
  if [ "$got" = "$expect" ]; then
    pass=$((pass+1)); echo "ok: $desc"
  else
    fail=$((fail+1)); echo "FAIL: $desc (expected $expect, got $got)"
    grep -iE "in 'cred|unknown field|required" "$WORK/out" | head -3 | sed 's/^/      /'
  fi
}

echo "== each method accepts its own record"
case_check "method=sts + sts record" accept \
'          credentials:
            method: sts
            sts: { service_account_id: sa }'
case_check "method=bearer_token + api_key" accept \
'          credentials:
            method: bearer_token
            bearer_token: { api_key: k }'
case_check "method=jwt_credential + service_account_json" accept \
'          credentials:
            method: jwt_credential
            jwt_credential: { service_account_json: "{}" }'

echo "== naming a method without its record fails at CONFIG time"
case_check "method=bearer_token, no bearer_token record" reject \
'          credentials:
            method: bearer_token
            sts: { service_account_id: sa }'
case_check "method=jwt_credential, no jwt_credential record" reject \
'          credentials:
            method: jwt_credential
            sts: { service_account_id: sa }'

echo "== ctx is DERIVED, never configured -- under every method"
# The plugin derives ctx itself, so there is nothing to configure ANYWHERE -- not
# even under jwt_credential. context_headers in particular was a spoofing vector:
# it lifted caller-controlled request headers into the claim set the vault trusts
# for policy decisions.
case_check "context_json rejected on jwt_credential (the plugin derives ctx)" reject \
'          credentials:
            method: jwt_credential
            jwt_credential:
              service_account_json: "{}"
              context_json: "{\"tenant\":\"acme\"}"'
case_check "context_headers rejected on jwt_credential (caller-forgeable)" reject \
'          credentials:
            method: jwt_credential
            jwt_credential:
              service_account_json: "{}"
              context_headers: { x-purpose: purpose }'
case_check "role_ids rejected on jwt_credential (roles are the vault's business)" reject \
'          credentials:
            method: jwt_credential
            jwt_credential:
              service_account_json: "{}"
              role_ids: [r1]'
case_check "ttl_seconds rejected on jwt_credential (Skyflow caps it server-side)" reject \
'          credentials:
            method: jwt_credential
            jwt_credential:
              service_account_json: "{}"
              ttl_seconds: 600'
case_check "context_json rejected on sts (Skyflow ignores it)" reject \
'          credentials:
            method: sts
            sts:
              service_account_id: sa
              context_json: "{\"tenant\":\"acme\"}"'
case_check "context_json rejected on bearer_token (no assertion)" reject \
'          credentials:
            method: bearer_token
            bearer_token:
              api_key: k
              context_json: "{\"tenant\":\"acme\"}"'
case_check "role_ids rejected on bearer_token" reject \
'          credentials:
            method: bearer_token
            bearer_token: { api_key: k, role_ids: [r1] }'

echo "== sts is the default (the only method holding no Skyflow credential)"
case_check "omitting method defaults to sts and validates" accept \
'          credentials:
            sts: { service_account_id: sa }'

echo ""
[ "$fail" -gt 0 ] && { echo "$fail FAILURES"; exit 1; }
echo "ALL PASS ($pass cases)"
