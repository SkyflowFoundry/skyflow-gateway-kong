#!/usr/bin/env sh
# Generate kong.yaml from kong.template.yaml using your environment.
# Required:
#   SKYFLOW_VAULT_ID, SKYFLOW_CLUSTER_ID, SKYFLOW_ACCOUNT_ID
#   SKYFLOW_SA_JSON      (the service-account credentials JSON, one line)
#   GATEWAY_API_KEY      (what clients send as apikey / x-api-key)
# Optional:
#   CTX_TENANT (default local-demo)
# Models are NOT pinned server-side -- callers pass any model the provider
# offers, so there is nothing to configure here.
set -eu
cd "$(dirname "$0")"

for v in SKYFLOW_VAULT_ID SKYFLOW_CLUSTER_ID SKYFLOW_ACCOUNT_ID SKYFLOW_SA_JSON GATEWAY_API_KEY; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || { echo "ERROR: $v is not set" >&2; exit 1; }
done

sed \
  -e "s/__SKYFLOW_VAULT_ID__/${SKYFLOW_VAULT_ID}/g" \
  -e "s/__SKYFLOW_CLUSTER_ID__/${SKYFLOW_CLUSTER_ID}/g" \
  -e "s/__SKYFLOW_ACCOUNT_ID__/${SKYFLOW_ACCOUNT_ID}/g" \
  -e "s/__CTX_TENANT__/${CTX_TENANT:-local-demo}/g" \
  -e "s|__GATEWAY_API_KEY__|${GATEWAY_API_KEY}|g" \
  kong.template.yaml > kong.yaml

echo "wrote deploy/claude-gateway/kong.yaml"
echo "next:  docker compose up -d"
