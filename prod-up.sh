#!/usr/bin/env bash
# file: prod-up.sh
# Purpose: end-to-end Cloudflare deploy for eBay Resell App (Linux)
# Why strict mode: fail fast and show clear errors for newbies
set -Eeuo pipefail

### --- SETTINGS YOU MAY CHANGE ---
REPO_DIR="${REPO_DIR:-$HOME/code/ebay-resell-ui}"      # Path to your UI repo
WORKER_NAME="${WORKER_NAME:-resell-api}"               # Worker service name
PAGES_PROJECT="${PAGES_PROJECT:-ebay-resell-ui}"       # Pages project
D1_NAME="${D1_NAME:-resellapp}"                        # D1 DB name
KV_NAMESPACE="${KV_NAMESPACE:-resell-cache}"           # KV namespace
R2_BUCKET="${R2_BUCKET:-resell-photos}"                # R2 bucket
API_URL="${API_URL:-https://resell-api.phoneman1224.workers.dev}"  # Worker URL
UI_URL="${UI_URL:-https://ebay-resell-ui.pages.dev}"               # Pages prod URL
CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-0de0f1a4ab3a36d280ab48f02806f241}"

# Pause at the end so windows don't auto-close
NO_PAUSE="${NO_PAUSE:-0}"

### --- UTILITIES ---
say(){ printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
ok(){  printf '   ✓ %s\n' "$*"; }
warn(){ printf '   ⚠ %s\n' "$*"; }
die(){  printf '\n✗ %s\n' "$*" >&2; exit 1; }

pause_end(){
  [[ "$NO_PAUSE" == "1" ]] && return 0
  printf '\n-- Press Enter to close -- ' >&2
  # shellcheck disable=SC2034
  read -r _ || true
}

trap 'status=$?; [[ $status -eq 0 ]] || warn "Script ended with exit code $status"; pause_end' EXIT

need(){
  command -v "$1" >/dev/null 2>&1 || die "Missing '$1'. Install it and rerun.
  - wrangler: npm i -g wrangler  (or) https://developers.cloudflare.com/workers/wrangler
  - node/npm: https://nodejs.org
  - curl:     sudo apt install curl"
}

ensure_token(){
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    say "Enter your CLOUDFLARE_API_TOKEN (input hidden)"
    # read silently; user pastes once
    read -rs -p "Token: " CLOUDFLARE_API_TOKEN; echo
    export CLOUDFLARE_API_TOKEN
  fi
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || die "CLOUDFLARE_API_TOKEN is required."
}

# Random hex for OWNER_TOKEN if none provided
rand_hex(){ openssl rand -hex 32 2>/dev/null || date +%s%N; }

### --- PRE-FLIGHT ---
say "Pre-flight checks"
need bash
need curl
need node
need npm
need wrangler
ok "tools present"

export CLOUDFLARE_ACCOUNT_ID
ensure_token

say "Wrangler auth check"
if ! wrangler whoami >/dev/null 2>&1; then
  die "Wrangler auth failed. Ensure token has Workers + Pages + D1 + R2 + KV permissions."
fi
ok "Wrangler authenticated (account $CLOUDFLARE_ACCOUNT_ID)"

### --- OWNER_TOKEN + CORS ---
say "Rotate OWNER_TOKEN and set ALLOWED_ORIGIN for Worker: $WORKER_NAME"
OWNER_TOKEN="${OWNER_TOKEN:-$(rand_hex)}"
# put secrets (non-interactive)
printf %s "$OWNER_TOKEN" | wrangler secret put OWNER_TOKEN --name "$WORKER_NAME" >/dev/null
# ALLOWED_ORIGIN as secret (works like a var, avoids leakage in UI)
printf %s "$UI_URL" | wrangler secret put ALLOWED_ORIGIN --name "$WORKER_NAME" >/dev/null || \
  warn "Could not set ALLOWED_ORIGIN as secret (may already exist as variable). Verify in Dashboard."
ok "Secrets set"

say "Auth smoke test"
if curl -fsS -H "X-Owner-Token: $OWNER_TOKEN" "$API_URL/debug/auth" | grep -qi '"ok"'; then
  ok "/debug/auth OK"
else
  warn "Auth check didn't return ok JSON yet. Continuing."
fi

### --- D1: ensure DB + minimal schema ---
say "Ensure D1 database: $D1_NAME"
wrangler d1 create "$D1_NAME" >/dev/null 2>&1 || true
ok "D1 exists (or created)"

SCHEMA_SQL="$(mktemp)"
cat >"$SCHEMA_SQL" <<'SQL'
-- Inventory
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

-- Sales
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

-- Expenses
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

wrangler d1 execute "$D1_NAME" --file "$SCHEMA_SQL" >/dev/null
rm -f "$SCHEMA_SQL"
ok "D1 schema ensured"

### --- KV + R2 (idempotent) ---
say "Ensure KV + R2"
wrangler kv namespace create "$KV_NAMESPACE" >/dev/null 2>&1 || true
ok "KV: $KV_NAMESPACE ready"
wrangler r2 bucket create "$R2_BUCKET" >/dev/null 2>&1 || true
ok "R2: $R2_BUCKET ready"

### --- PAGES UI DEPLOY ---
say "Build and deploy UI to Pages: $PAGES_PROJECT"
if [[ ! -d "$REPO_DIR" ]]; then
  warn "REPO_DIR '$REPO_DIR' not found. Using current directory: $PWD"
  REPO_DIR="$PWD"
fi

pushd "$REPO_DIR" >/dev/null || die "Cannot cd into $REPO_DIR"

# Provide API base for prod build
printf 'PUBLIC_API_BASE_URL=%s\n' "$API_URL" > .env.production

BUILD_DIR="."
if [[ -f package.json ]]; then
  if grep -q '"build"' package.json; then
    say "Installing deps and building (npm ci && npm run build)"
    (command -v npm >/dev/null && npm ci --prefer-offline || npm install)
    npm run build
    # Common build dirs
    for d in dist build .output/public out; do
      if [[ -d "$d" ]]; then BUILD_DIR="$d"; break; fi
    done
    ok "Build complete (dir: $BUILD_DIR)"
  else
    warn "No build script in package.json; deploying source dir."
  fi
else
  warn "No package.json; deploying static files."
fi

# Create project if not exists
wrangler pages project create "$PAGES_PROJECT" --production-branch=main >/dev/null 2>&1 || true

# Deploy build dir
wrangler pages deploy "$BUILD_DIR" --project-name="$PAGES_PROJECT" --branch=main --commit-dirty=true >/dev/null
popd >/dev/null
ok "Pages deployed (check: $UI_URL)"

### --- API SMOKE TESTS ---
say "API smoke tests"
curl -fsS "$API_URL/health" >/dev/null && ok "/health OK" || die "/health failed"

# Create → List → Patch
curl -fsS -X POST "$API_URL/inventory" -H 'Content-Type: application/json' \
  -d '{"sku":"SKU-TEST","title":"Demo","category":"Shoes","cost_usd":12.50,"quantity":1}' >/dev/null && ok "create OK" || warn "create failed"

LIST_JSON="$(curl -fsS "$API_URL/inventory" || true)"
ID="$(printf '%s\n' "$LIST_JSON" | sed -n 's/.*"id":"\([^"]\+\)".*/\1/p' | head -n1 || true)"
if [[ -n "$ID" ]]; then
  ok "list OK (id $ID)"
  curl -fsS -X PATCH -H "X-Owner-Token: $OWNER_TOKEN" -H 'Content-Type: application/json' \
    -d '{"status":"active","quantity":2}' "$API_URL/inventory/$ID" >/dev/null && ok "patch OK" || warn "patch failed"
else
  warn "list did not return an id; skipping patch"
fi

say "DONE ✅  Open $UI_URL, paste OWNER_TOKEN when prompted, then Load."
