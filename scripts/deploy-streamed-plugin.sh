#!/usr/bin/env bash
# Roll a new build of the streamed plugin out to every control plane, and bring
# existing plugin instances in line with the new schema.
#
# Ordering is load-bearing. A data plane validates each plugin instance against
# the streamed schema and rejects the ENTIRE config if any instance fails,
# silently serving its last-good config. So we upload the new schema FIRST and
# fix up the instances SECOND: in between, instances carrying a field the new
# schema no longer knows are rejected and the gateway keeps serving the previous
# config -- no outage. Doing it the other way round would leave a window where an
# instance validates but scans the wrong JSON paths, which is the silent
# under-scan this plugin exists to prevent.
#
# Usage:
#   DECK_KONNECT_TOKEN=kpat_...  scripts/deploy-streamed-plugin.sh [--dry-run]
#   # or put the token in a file and:
#   KONNECT_TOKEN_FILE=/path/to/token  scripts/deploy-streamed-plugin.sh
set -euo pipefail

ADDR="${DECK_KONNECT_ADDR:-https://us.api.konghq.com}"
BUNDLE="${BUNDLE:-custom-plugin.json}"
PLUGIN_NAME="skyflow-ai-data-control"
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

# Fields the current schema no longer accepts. A stored instance carrying any of
# these is rejected wholesale by the data plane, so they are stripped on PUT.
RETIRED_FIELDS='["profile"]'

TOKEN="${DECK_KONNECT_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -n "${KONNECT_TOKEN_FILE:-}" ]; then
  TOKEN="$(tr -d '[:space:]' < "$KONNECT_TOKEN_FILE")"
fi
if [ -z "$TOKEN" ]; then
  echo "error: no token. Set DECK_KONNECT_TOKEN or KONNECT_TOKEN_FILE." >&2
  exit 2
fi
[ -f "$BUNDLE" ] || { echo "error: $BUNDLE not found -- run 'make bundle' first." >&2; exit 2; }

api() {  # api METHOD PATH [json-body]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" "$ADDR$path" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      --data-binary "$body" -w '\n%{http_code}'
  else
    curl -sS -X "$method" "$ADDR$path" \
      -H "Authorization: Bearer $TOKEN" -w '\n%{http_code}'
  fi
}

check() {  # check <response-with-trailing-status> <context>
  local resp="$1" ctx="$2" code
  code="$(printf '%s' "$resp" | tail -1)"
  case "$code" in
    2*) return 0 ;;
    *)  echo "  FAILED ($code) $ctx" >&2
        printf '%s' "$resp" | sed '$d' | head -c 600 >&2; echo >&2
        return 1 ;;
  esac
}
body_of() { printf '%s' "$1" | sed '$d'; }

echo "== control planes"
CPS="$(api GET '/v2/control-planes?page[size]=100')"
check "$CPS" "listing control planes"
# `mapfile` is bash 4+; macOS ships 3.2, so read into the array the portable way.
CP_IDS=()
while IFS= read -r line; do [ -n "$line" ] && CP_IDS+=("$line"); done < <(
  body_of "$CPS" | jq -r '.data[] | "\(.id)\t\(.name)"')
[ "${#CP_IDS[@]}" -gt 0 ] || { echo "no control planes found" >&2; exit 1; }
printf '  %s\n' "${CP_IDS[@]}"

VERSION="$(jq -r '.handler' "$BUNDLE" | grep -o 'VERSION = "[^"]*"' | head -1 | sed 's/.*"\(.*\)"/\1/')"
echo "== bundle: $PLUGIN_NAME v${VERSION:-?}, handler $(jq -r '.handler|length' "$BUNDLE") bytes"

for row in "${CP_IDS[@]}"; do
  CP_ID="${row%%$'\t'*}"; CP_NAME="${row#*$'\t'}"

  # Only touch control planes that already carry this plugin. Uploading it
  # everywhere would be a scope change, not a deploy.
  EXISTING="$(api GET "/v2/control-planes/$CP_ID/core-entities/custom-plugins?page[size]=100")"
  check "$EXISTING" "listing custom plugins on $CP_NAME" || continue
  CP_HAS="$(body_of "$EXISTING" | jq -r --arg n "$PLUGIN_NAME" '.data[]|select(.name==$n)|.id' | head -1)"
  [ -n "$CP_HAS" ] || { echo "-- $CP_NAME: $PLUGIN_NAME not installed, skipping"; continue; }

  echo "-- $CP_NAME"

  # ---- step 1: the schema + handler.
  if $DRY_RUN; then
    echo "   [dry-run] would PUT custom-plugins/$PLUGIN_NAME"
  else
    # --data-binary @file, so this one does not go through api().
    R="$(curl -sS -X PUT "$ADDR/v2/control-planes/$CP_ID/core-entities/custom-plugins/$PLUGIN_NAME" \
          -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
          --data-binary "@$BUNDLE" -w '\n%{http_code}')"
    check "$R" "uploading plugin to $CP_NAME" || continue
    echo "   uploaded v${VERSION:-?}"
  fi

  # ---- step 2: bring stored instances in line with the new schema.
  INST="$(api GET "/v2/control-planes/$CP_ID/core-entities/plugins?page[size]=100")"
  check "$INST" "listing plugin instances on $CP_NAME" || continue
  STALE=()
  while IFS= read -r line; do [ -n "$line" ] && STALE+=("$line"); done < <(
    body_of "$INST" | jq -c --arg n "$PLUGIN_NAME" --argjson rf "$RETIRED_FIELDS" \
      '.data[] | select(.name==$n) | select([.config|keys[]] as $k | any($rf[]; . as $f | $k|index($f)))')

  if [ "${#STALE[@]}" -eq 0 ]; then
    echo "   instances: none carry retired fields"
  fi
  for inst in ${STALE[@]+"${STALE[@]}"}; do
    [ -n "$inst" ] || continue
    IID="$(printf '%s' "$inst" | jq -r '.id')"
    WHERE="$(printf '%s' "$inst" | jq -r '(.route.id // .service.id // "global")')"
    DROPPED="$(printf '%s' "$inst" | jq -r --argjson rf "$RETIRED_FIELDS" \
      '[.config|keys[]] as $k | [$rf[]|select(. as $f | $k|index($f))] | join(",")')"
    # PUT (replace), not PATCH: once the field is unknown to the schema, a merge
    # that carries the stored copy forward fails validation.
    CLEAN="$(printf '%s' "$inst" | jq -c --argjson rf "$RETIRED_FIELDS" \
      'del(.created_at, .updated_at) | .config |= with_entries(select(.key as $k | ($rf|index($k))|not))')"
    if $DRY_RUN; then
      echo "   [dry-run] would strip {$DROPPED} from instance $IID (on $WHERE)"
    else
      R="$(api PUT "/v2/control-planes/$CP_ID/core-entities/plugins/$IID" "$CLEAN")"
      check "$R" "updating instance $IID on $CP_NAME" || continue
      echo "   stripped {$DROPPED} from instance $IID (on $WHERE)"
    fi
  done

  # ---- step 3: did the data planes actually take it?
  NODES="$(api GET "/v2/control-planes/$CP_ID/nodes")"
  if check "$NODES" "listing nodes on $CP_NAME"; then
    body_of "$NODES" | jq -r '.items[]? | "   node \(.hostname // .id): \(.config_hash[0:12]) \(.sync_status // "?")"'
  fi
done

echo
echo "A config_hash that has NOT moved means the data plane rejected the config and"
echo "is still serving its last-good copy. Check the DP log for 'declarative config"
echo "is invalid' before assuming the rollout landed."
