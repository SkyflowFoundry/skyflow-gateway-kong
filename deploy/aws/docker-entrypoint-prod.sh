#!/bin/sh
# Render the declarative config from env at boot (App Runner injects the
# secret values from Secrets Manager), then hand off to Kong's own entrypoint.
set -eu
# STS-only deployment: no SKYFLOW_SA_JSON and no GATEWAY_API_KEY -- this
# gateway holds no Skyflow credential and issues none to clients.
#
# Accept the SKYFLOW_*-prefixed names as aliases. The other two deployment paths
# (deploy/konnect and the LiteLLM gateway) use SKYFLOW_STS_SERVICE_ACCOUNT_ID /
# SKYFLOW_IDP_ISSUER / SKYFLOW_IDP_AUDIENCE, and only this one used the bare
# STS_/ENTRA_ forms -- so copying the env from a working deployment made this
# container exit with "FATAL: STS_SERVICE_ACCOUNT_ID is not set" and no hint that
# the value was present under a different name. Aliasing is cheaper than three
# sets of docs that must agree.
: "${STS_SERVICE_ACCOUNT_ID:=${SKYFLOW_STS_SERVICE_ACCOUNT_ID:-}}"
: "${ENTRA_ISSUER:=${SKYFLOW_IDP_ISSUER:-}}"
: "${ENTRA_AUDIENCE:=${SKYFLOW_IDP_AUDIENCE:-}}"
export STS_SERVICE_ACCOUNT_ID ENTRA_ISSUER ENTRA_AUDIENCE

for v in SKYFLOW_VAULT_ID SKYFLOW_CLUSTER_ID SKYFLOW_ACCOUNT_ID \
         STS_SERVICE_ACCOUNT_ID ENTRA_ISSUER ENTRA_AUDIENCE; do
  eval "val=\${$v:-}"
  if [ -z "$val" ]; then
    echo "FATAL: $v is not set" >&2
    case "$v" in
      STS_SERVICE_ACCOUNT_ID) echo "  (also accepted: SKYFLOW_STS_SERVICE_ACCOUNT_ID)" >&2 ;;
      ENTRA_ISSUER)           echo "  (also accepted: SKYFLOW_IDP_ISSUER)" >&2 ;;
      ENTRA_AUDIENCE)         echo "  (also accepted: SKYFLOW_IDP_AUDIENCE)" >&2 ;;
    esac
    exit 1
  fi
done
sed \
  -e "s/__SKYFLOW_VAULT_ID__/${SKYFLOW_VAULT_ID}/g" \
  -e "s/__SKYFLOW_CLUSTER_ID__/${SKYFLOW_CLUSTER_ID}/g" \
  -e "s/__SKYFLOW_ACCOUNT_ID__/${SKYFLOW_ACCOUNT_ID}/g" \
  -e "s/__STS_SERVICE_ACCOUNT_ID__/${STS_SERVICE_ACCOUNT_ID}/g" \
  -e "s/__CTX_TENANT__/${CTX_TENANT:-skyflow-team}/g" \
  `# pipe delimiters: these values are URLs containing slashes` \
  -e "s|__ENTRA_ISSUER__|${ENTRA_ISSUER}|g" \
  -e "s|__ENTRA_AUDIENCE__|${ENTRA_AUDIENCE}|g" \
  /kong-prod.template.yaml > /tmp/kong.yaml
# Fail fast if any placeholder survived substitution. A literal __FOO__ left in
# the config renders as a plausible-looking value (e.g. expected_issuer:
# "__ENTRA_ISSUER__"), so Kong boots and requests fail confusingly at runtime
# instead of here. Cost me a deploy cycle; never again.
if grep -o '__[A-Z_]*__' /tmp/kong.yaml | sort -u | head -5 | grep -q .; then
  echo "FATAL: unsubstituted placeholders remain in the rendered config:" >&2
  grep -o '__[A-Z_]*__' /tmp/kong.yaml | sort -u >&2
  exit 1
fi

export KONG_DECLARATIVE_CONFIG=/tmp/kong.yaml
exec /entrypoint.sh kong docker-start
