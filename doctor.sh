#!/usr/bin/env bash
# file: doctor.sh
set -Eeuo pipefail

OUT="${OUT:-diagnostics.txt}"
LOG="${LOG:-log.txt}"
BASE_DIR="${BASE_DIR:-$PWD}"

say(){ printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
sec(){ printf '\n--- %s ---\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
http_status(){ curl -o /dev/null -sS -w "%{http_code}" "$1" 2>/dev/null || echo "000"; } # only status code

cd "$BASE_DIR"

API_URL_DEFAULT="https://resell-api.phoneman1224.workers.dev"
API_BASE="$( (test -f api_base_url.txt && sed -n '1p' api_base_url.txt) || echo "$API_URL_DEFAULT" )"
OWNER_TOKEN="$( (test -f owner_token.txt && sed -n '1p' owner_token.txt) || echo "" )"

{
  echo "# eBay Resell App Diagnostics $(date -Is)"

  sec "System"
  echo "uname: $(uname -a || true)"
  echo "node:  $(node -v || true)"
  echo "npm:   $(npm -v || true)"
  echo "wrangler: $(wrangler --version || true)"

  sec "Paths"
  echo "PWD: $PWD"
  echo "Detected API_BASE: $API_BASE"
  echo "owner_token.txt: $(test -f owner_token.txt && echo present || echo missing)"
  echo "log.txt: $(test -f "$LOG" && echo present || echo missing)"

  sec "Recent log tail (last 200 lines)"
  if test -f "$LOG"; then tail -n 200 "$LOG"; else echo "log file not found"; fi

  sec "Log error scan (ERROR/failed/✗/4xx/5xx, last 400 lines)"
  if test -f "$LOG"; then
    tail -n 400 "$LOG" | grep -Eni '✗|error|failed|failure| 4[0-9]{2} | 5[0-9]{2} ' || echo "no obvious errors"
  else
    echo "log file not found"
  fi

  sec "HTTP health checks"
  H_ROOT="$(http_status "$API_BASE/health")"
  H_API="$(http_status "$API_BASE/api/health")"
  echo "$API_BASE/health     -> $H_ROOT"
  echo "$API_BASE/api/health -> $H_API"

  sec "Auth check (/debug/auth with token if available)"
  if [ -n "$OWNER_TOKEN" ]; then
    A1="$(curl -o /dev/null -sS -w "%{http_code}" -H "X-Owner-Token: $OWNER_TOKEN" "$API_BASE/debug/auth" || echo "000")"
    echo "$API_BASE/debug/auth -> $A1 (with X-Owner-Token)"
  else
    echo "No owner_token.txt; skipped"
  fi

  sec "Inventory round-trip (best effort)"
  set +e
  curl -fsS -X POST "$API_BASE/inventory" -H 'Content-Type: application/json' \
    -d '{"sku":"SKU-DIAG","title":"Diag","category":"Shoes","cost_usd":1.23,"quantity":1}' >/dev/null
  POST_RC=$?
  echo "POST /inventory rc=$POST_RC"
  curl -fsS "$API_BASE/inventory" | head -c 600 || true
  echo
  set -e

  sec "D1 quick probe (remote)"
  SQL=$(mktemp); echo 'SELECT 1 as ok;' > "$SQL"
  if wrangler d1 execute resellapp --remote --file "$SQL" >/dev/null 2>&1; then
    echo "D1 execute remote: OK"
  else
    echo "D1 execute remote: FAIL"
  fi
  rm -f "$SQL"
} | tee "$OUT"

say "Diagnostics written to: $(realpath "$OUT")"
