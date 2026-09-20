#!/usr/bin/env bash
set -euo pipefail

# destroy.sh — delete the sandbox created by deploy.sh.
#
#   ./destroy.sh              delete the sandbox in .sandbox-id
#   ./destroy.sh <sandbox-id> delete a specific sandbox

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
STATE_FILE="$SCRIPT_DIR/.sandbox-id"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.example -> .env and fill it in." >&2
  exit 1
fi
set -a; . "$ENV_FILE"; set +a

: "${endpoint:?endpoint not set in .env}"
: "${api_key:?api_key not set in .env}"

BASE="https://${endpoint}/v1"
AUTH="Authorization: Bearer ${api_key}"

# An explicit id overrides the state file (e.g. after losing .sandbox-id).
if [ "${1:-}" != "" ]; then
  ID="$1"
elif [ -f "$STATE_FILE" ]; then
  ID="$(cat "$STATE_FILE")"
else
  echo "ERROR: $STATE_FILE not found. Run ./deploy.sh first (or pass a sandbox id)." >&2
  echo "Usage: $0 [sandbox-id]" >&2
  exit 1
fi

echo "[destroy] deleting sandbox $ID"
curl --retry 3 --retry-delay 2 --retry-all-errors --max-time 30 -fsS -X DELETE \
  -H "$AUTH" "$BASE/sandboxes/$ID" -o /dev/null
rm -f "$STATE_FILE"
echo "[destroy] done"
