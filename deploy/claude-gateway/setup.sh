#!/usr/bin/env sh
# Generate kong.yaml from kong.template.yaml using your environment.
# Required:
#   SKYFLOW_VAULT_ID, SKYFLOW_CLUSTER_ID, SKYFLOW_ACCOUNT_ID
#   SKYFLOW_SA_JSON      (the service-account credentials JSON, one line)
# Optional:
#   OPENAI_MODEL (default gpt-4o-mini), CTX_TENANT (default local-demo)
set -eu
cd "$(dirname "$0")"

for v in SKYFLOW_VAULT_ID SKYFLOW_CLUSTER_ID SKYFLOW_ACCOUNT_ID SKYFLOW_SA_JSON; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || { echo "ERROR: $v is not set" >&2; exit 1; }
done

sed \
  -e "s/__SKYFLOW_VAULT_ID__/${SKYFLOW_VAULT_ID}/g" \
  -e "s/__SKYFLOW_CLUSTER_ID__/${SKYFLOW_CLUSTER_ID}/g" \
  -e "s/__SKYFLOW_ACCOUNT_ID__/${SKYFLOW_ACCOUNT_ID}/g" \
  -e "s/__OPENAI_MODEL__/${OPENAI_MODEL:-gpt-4o-mini}/g" \
  -e "s/__CTX_TENANT__/${CTX_TENANT:-local-demo}/g" \
  kong.template.yaml > kong.yaml

echo "wrote deploy/claude-gateway/kong.yaml"
echo "next:  docker compose up -d"
