#!/usr/bin/env bash
# file: resell-run.sh (v2 with API base auto-detect)
set -Eeuo pipefail

# ---------- LOGGING ----------
LOG_FILE="${LOG_FILE:-log.txt}"
if command -v tee >/dev/null 2>&1; then exec > >(tee -a "$LOG_FILE") 2>&1; else exec >>"$LOG_FILE" 2>&1; fi

# ---------- CONFIG ----------
REPO_DIR="${REPO_DIR:-$PWD}"               # repo root (you are already in ~/code/ebay-resell-ui)
UI_DIR=""                                  # auto-detected (./ui or .)
WORKER_NAME="${WORKER_NAME:-resell-api}"
PAGES_PROJECT="${PAGES_PROJECT:-ebay-resell-ui}"
D1_NAME="${D1_NAME:-resellapp}"
KV_NAMESPACE="${KV_NAMESPACE:-resell-cache}"
R2_BUCKET="${R2_BUCKET:-resell-photos}"

API_URL="${API_URL:-https://resell-api.phoneman1224.workers.dev}"   # base host
UI_URL="${UI_URL:-https://ebay-resell-ui.pages.dev}"                # Pages prod URL

NO_PAUSE="${NO_PAUSE:-0}"

say(){ printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
ok(){  printf '   ✓ %s\n' "$*"; }
warn(){ printf '   ⚠ %s\n' "$*"; }
die(){  printf '\n✗ %s\n' "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
pause_end(){ [[ "$NO_PAUSE" == "1" ]] || { printf '\n-- Press Enter to close -- ' >&2; read -r _ || true; }; }
rand_hex(){ openssl rand -hex 32 2>/dev/null || date +%s%N; }
trap 's=$?; [[ $s -eq 0 ]] || warn "Exit code: $s"; say "Logs saved to: $(realpath "$LOG_FILE")"; pause_end' EXIT

pm_detect(){ for p in apt-get dnf yum pacman zypper; do have "$p" && { echo "$p"; return; }; done; echo ""; }
pm_install(){ case "$1" in
  apt-get) sudo apt-get update -y && sudo apt-get install -y "${@:2}" ;;
  dnf)     sudo dnf install -y "${@:2}" ;;
  yum)     sudo yum install -y "${@:2}" ;;
  pacman)  sudo pacman -Sy --noconfirm "${@:2}" ;;
  zypper)  sudo zypper install -y "${@:2}" ;;
  *)       return 1 ;;
esac; }

ensure_curl(){ have curl || { local pm; pm="$(pm_detect)"; [[ -n "$pm" ]] || die "Install curl manually."; pm_install "$pm" curl || die "Failed to install curl"; ok "curl installed"; }; }
ensure_node_npm(){
  if have node && have npm; then ok "node/npm present ($(node -v))"; return; fi
  say "Installing node + npm (required by wrangler)"; local pm; pm="$(pm_detect)"; [[ -n "$pm" ]] || die "No supported package manager found."
  pm_install "$pm" nodejs npm || die "Failed to install nodejs/npm via $pm"; ok "node/npm installed"
}
ensure_wrangler(){
  if have wrangler; then ok "wrangler present ($(wrangler --version | head -n1))"; return; fi
  say "Installing wrangler"; have npm || ensure_node_npm; npm i -g wrangler >/dev/null 2>&1 || die "wrangler install failed"; ok "wrangler installed"
}

auth_cloudflare(){
  say "Authenticating with Cloudflare"
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    ok "Using CLOUDFLARE_API_TOKEN"; wrangler whoami >/dev/null 2>&1 && { ok "whoami OK (token)"; return; }
    warn "Token present but whoami failed; trying interactive login…"
  fi
  wrangler login >/dev/null 2>&1 && wrangler whoami >/dev/null 2>&1 || die "Cloudflare auth failed"
  ok "wrangler login OK"
}

ensure_repo(){
  say "Repo / UI detection"
  [[ -d "$REPO_DIR" ]] || die "REPO_DIR '$REPO_DIR' not found; cd into your repo and re-run."
  if [[ -f "$REPO_DIR/ui/package.json" ]]; then UI_DIR="$REPO_DIR/ui"; else UI_DIR="$REPO_DIR"; fi
  ok "UI_DIR = $UI_DIR"
}

# ----------- API base detection: tries /health then /api/health -----------
detect_api_base(){
  say "Detecting API base path on $API_URL"
  local base="$API_URL"
  if curl -fsS "$base/health" >/dev/null 2>&1; then
    API_BASE="$base"; API_BASE_PATH=""
    ok "Using API base: $API_BASE (no /api)"
  elif curl -fsS "$base/api/health" >/dev/null 2>&1; then
    API_BASE="$base/api"; API_BASE_PATH="/api"
    ok "Using API base: $API_BASE (/api prefix)"
  else
    warn "Health check failed at both /health and /api/health — continuing (Worker may block unauthd paths or be cold)."
    API_BASE="$base"; API_BASE_PATH=""
  fi
  printf '%s\n' "$API_BASE" > api_base_url.txt
  ok "Saved API base to ./api_base_url.txt"
}

set_worker_secrets(){
  say "Setting Worker secrets: OWNER_TOKEN + ALLOWED_ORIGIN"
  local token="${OWNER_TOKEN:-$(rand_hex)}"
  printf %s "$token" | wrangler secret put OWNER_TOKEN --name "$WORKER_NAME" >/dev/null || warn "Could not set OWNER_TOKEN (does Worker '$WORKER_NAME' exist?)"
  printf %s "$UI_URL" | wrangler secret put ALLOWED_ORIGIN --name "$WORKER_NAME" >/dev/null || warn "ALLOWED_ORIGIN likely exists as plain var; leave as-is in Dashboard"
  umask 177; echo "$token" > owner_token.txt; umask 022; ok "OWNER_TOKEN saved to ./owner_token.txt"

  say "Auth probe"
  if curl -fsS -H "X-Owner-Token: $token" "$API_BASE/debug/auth" | grep -qi '"ok"'; then ok "Auth OK"; else warn "Auth probe not OK (will continue)"; fi
  export OWNER_TOKEN="$token"
}

ensure_cf_resources(){
  say "Ensuring D1 / KV / R2 exist"
  wrangler d1 create "$D1_NAME" >/dev/null 2>&1 || true
  wrangler kv namespace create "$KV_NAMESPACE" >/dev/null 2>&1 || true
  wrangler r2 bucket create "$R2_BUCKET" >/dev/null 2>&1 || true
  ok "Cloudflare resources present"
}

apply_d1_schema(){
  say "Applying D1 schema (remote)"
  local schema; schema="$(mktemp)"
  cat >"$schema" <<'SQL'
CREATE TABLE IF NOT EXISTS Inventory (
  id TEXT PRIMARY KEY,
  sku TEXT UNIQUE NOT NULL,
  title TEXT NOT NULL,
  category TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('staged','draft','active','sold')),
  cost_cents INTEGER NOT NULL DEFAULT 0,
  quantity INTEGER NOT NULL DEFAULT 0,
  listed_date TEXT NULL,
  draft_created_at TEXT NULL,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_inventory_sku ON Inventory(sku);
CREATE INDEX IF NOT EXISTS idx_inventory_status ON Inventory(status);

CREATE TABLE IF NOT EXISTS Sales (
  id TEXT PRIMARY KEY,
  date TEXT NOT NULL,
  inventory_id TEXT NULL,
  sku TEXT NOT NULL,
  qty INTEGER NOT NULL,
  sold_price_cents INTEGER NOT NULL,
  buyer_shipping_cents INTEGER NOT NULL DEFAULT 0,
  platform_fees_cents INTEGER NOT NULL DEFAULT 0,
  promo_fee_cents INTEGER NOT NULL DEFAULT 0,
  shipping_label_cost_cents INTEGER NOT NULL DEFAULT 0,
  other_costs_cents INTEGER NOT NULL DEFAULT 0,
  order_ref TEXT NOT NULL,
  note TEXT NULL,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_sales_date ON Sales(date);
CREATE INDEX IF NOT EXISTS idx_sales_sku ON Sales(sku);

CREATE TABLE IF NOT EXISTS Expenses (
  id TEXT PRIMARY KEY,
  date TEXT NOT NULL,
  category TEXT NOT NULL,
  amount_cents INTEGER NOT NULL,
  vendor TEXT NULL,
  note TEXT NULL,
  sku TEXT NULL,
  type TEXT NOT NULL DEFAULT 'standard',
  miles INTEGER NULL,
  rate_cents_per_mile INTEGER NULL,
  calc_amount_cents INTEGER NULL,
  deductible INTEGER NOT NULL DEFAULT 1,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_expenses_date ON Expenses(date);
CREATE INDEX IF NOT EXISTS idx_expenses_category ON Expenses(category);
SQL
  wrangler d1 execute "$D1_NAME" --remote --file "$schema" >/dev/null
  rm -f "$schema"
  ok "D1 schema applied"
}

deploy_pages(){
  say "Deploying UI to Pages"
  pushd "$UI_DIR" >/dev/null || die "cd into UI_DIR failed"
  # Use detected API base (may include /api)
  printf 'PUBLIC_API_BASE_URL=%s\n' "$API_BASE" > .env.production
  local build_dir="."
  if [[ -f package.json ]] && grep -q '"build"' package.json; then
    say "Building UI"; (have npm && npm ci --prefer-offline || npm install); npm run build
    for d in dist build .output/public out; do [[ -d "$d" ]] && { build_dir="$d"; break; }; done
    ok "Build complete (dir: $build_dir)"
  else
    warn "No build script; deploying source directory"
  fi
  wrangler pages project create "$PAGES_PROJECT" --production-branch=main >/dev/null 2>&1 || true
  wrangler pages deploy "$build_dir" --project-name="$PAGES_PROJECT" --branch=main --commit-dirty=true >/dev/null
  popd >/dev/null
  ok "Pages deployed to $UI_URL"
}

smoke_tests(){
  say "API smoke tests against $API_BASE"
  curl -fsS "$API_BASE/health" >/dev/null && ok "/health OK" || die "/health failed"
  curl -fsS -X POST "$API_BASE/inventory" -H 'Content-Type: application/json' \
    -d '{"sku":"SKU-TEST","title":"Demo","category":"Shoes","cost_usd":12.50,"quantity":1}' >/dev/null && ok "create OK" || warn "create failed"
  local list_json id
  list_json="$(curl -fsS "$API_BASE/inventory" || true)"
  id="$(printf '%s\n' "$list_json" | sed -n 's/.*"id":"\([^"]\+\)".*/\1/p' | head -n1 || true)"
  if [[ -n "$id" ]]; then
    ok "list OK (id $id)"
    curl -fsS -X PATCH -H "X-Owner-Token: $OWNER_TOKEN" -H 'Content-Type: application/json' \
      -d '{"status":"active","quantity":2}' "$API_BASE/inventory/$id" >/dev/null && ok "patch OK" || warn "patch failed"
  else
    warn "list returned no id; skipping patch"
  fi
}

summary(){
  say "SUMMARY"
  echo "  Worker:        $WORKER_NAME"
  echo "  Pages project: $PAGES_PROJECT"
  echo "  UI URL:        $UI_URL"
  echo "  API URL host:  $API_URL"
  echo "  API BASE used: $(cat api_base_url.txt 2>/dev/null || echo '?')"
  echo "  D1 DB:         $D1_NAME"
  echo "  KV:            $KV_NAMESPACE"
  echo "  R2:            $R2_BUCKET"
  echo "  Owner token:   saved to ./owner_token.txt (NOT in log)"
  say "Logs saved to: $(realpath "$LOG_FILE")"
}

main(){
  say "Starting deploy (log -> $LOG_FILE)"
  have curl || (say "Installing curl"; local pm; pm="$(pm_detect)"; [[ -n "$pm" ]] || die "Install curl"; pm_install "$pm" curl; ok "curl installed")
  ensure_node_npm; ensure_wrangler; auth_cloudflare; ensure_repo
  detect_api_base
  set_worker_secrets
  ensure_cf_resources
  apply_d1_schema
  deploy_pages
  smoke_tests
  summary
  ok "DONE ✅  Open $UI_URL, paste token from owner_token.txt, then Load."
}
main "$@"
