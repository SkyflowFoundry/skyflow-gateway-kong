#!/bin/sh
# Render the declarative config from env at boot (App Runner injects the
# secret values from Secrets Manager), then hand off to Kong's own entrypoint.
set -eu
for v in SKYFLOW_VAULT_ID SKYFLOW_CLUSTER_ID SKYFLOW_ACCOUNT_ID SKYFLOW_SA_JSON GATEWAY_API_KEY; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || { echo "FATAL: $v is not set" >&2; exit 1; }
done
sed \
  -e "s/__SKYFLOW_VAULT_ID__/${SKYFLOW_VAULT_ID}/g" \
  -e "s/__SKYFLOW_CLUSTER_ID__/${SKYFLOW_CLUSTER_ID}/g" \
  -e "s/__SKYFLOW_ACCOUNT_ID__/${SKYFLOW_ACCOUNT_ID}/g" \
  -e "s/__GATEWAY_API_KEY__/${GATEWAY_API_KEY}/g" \
  -e "s/__OPENAI_MODEL__/${OPENAI_MODEL:-gpt-4o-mini}/g" \
  -e "s/__ANTHROPIC_MODEL__/${ANTHROPIC_MODEL:-claude-sonnet-4-5}/g" \
  -e "s/__CTX_TENANT__/${CTX_TENANT:-skyflow-team}/g" \
  /kong-prod.template.yaml > /tmp/kong.yaml
export KONG_DECLARATIVE_CONFIG=/tmp/kong.yaml
exec /entrypoint.sh kong docker-start
