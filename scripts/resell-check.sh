#!/usr/bin/env bash
set -euo pipefail
API_BASE="${API_BASE:-https://resell-api.phoneman1224.workers.dev/api}"
echo "Health -> ${API_BASE}/health"
curl -fsS "${API_BASE}/health" | jq .
echo
echo "Inventory (list) -> ${API_BASE}/inventory"
curl -fsS "${API_BASE}/inventory" | jq .
