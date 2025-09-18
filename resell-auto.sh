#!/usr/bin/env bash
# file: resell-auto.sh
set -Eeuo pipefail

# ---- CONFIG (edit if your names differ) ----
REPO_DIR="${REPO_DIR:-$HOME/code/ebay-resell-ui}"
UI_GIT="${UI_GIT:-}"                         # set to your repo URL to auto-clone if missing
WORKER_NAME="${WORKER_NAME:-resell-api}"
PAGES_PROJECT="${PAGES_PROJECT:-ebay-resell-ui}"
D1_NAME="${D1_NAME:-resellapp}"
KV_NAMESPACE="${KV_NAMESPACE:-resell-cache}"
R2_BUCKET="${R2_BUCKET:-resell-photos}"
API_URL="${API_URL:-https://resell-api.phoneman1224.workers.dev}"
UI_URL="${UI_URL:-https://ebay-resell-ui.pages.dev}"
CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-0de0f1a4ab3a36d280ab48f02806f241}"
NO_PAUSE="${NO_PAUSE:-0}"

# ---- UTIL ----
say(){ printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
ok(){  printf '   ✓ %s\n' "$*"; }
warn(){ printf '   ⚠ %s\n' "$*"; }
die(){  printf '\n✗ %s\n' "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
rand_hex(){ openssl rand -hex 32 2>/dev/null || date +%s%N; }
pause_end(){ if [[ "$NO_PAUSE" != "1" ]]; then printf '\n-- Press Enter to close -- ' >&2; read -r _ || true; fi; }
trap 's=$?; [[ $s -eq 0 ]] || warn "Exit code: $s"; pause_end' EXIT

pm_detect(){ for p in apt-get dnf yum pacman zypper; do have "$p" && { echo "$p"; return; }; done; echo ""; }
pm_install(){ case "$1" in
  apt-get) sudo apt-get update -y && sudo apt-get install -y "${@:2}" ;;
  dnf)     sudo dnf install -y "${@:2}" ;;
  yum)     sudo yum install -y "${@:2}" ;;
  pacman)  sudo pacman -Sy --noconfirm "${@:2}" ;;
  zypper)  sudo zypper install -y "${@:2}" ;;
  *)       return 1 ;;
esac; }

ensure_node_npm(){
  if have node && have npm; then ok "node/npm present"; return; fi
  say "Installing node/npm (needed by wrangler)"
  local pm; pm="$(pm_detect)"; [[ -n "$pm" ]] || die "No supported package manager."
  pm_install "$pm" nodejs npm || die "Failed to install nodejs/npm"
  ok "node/npm installed"
}

ensure_wrangler(){
  if have wrangler; then ok "wrangler present"; return; fi
  say "Installing wrangler"
  have npm || ensure_node_npm
  npm install -g wrangler >/dev/null 2>&1 || die "wrangler install failed"
  ok "wrangler installed"
}

ensure_git(){
  have git && return
  say "Installing git"
  local pm; pm="$(pm_detect)"; [[ -n "$pm" ]] || die "No supported package manager."
  pm_install "$pm" git || die "git install failed"
  ok "git installed"
}

ensure_cf_auth(){
  export CLOUDFLARE_ACCOUNT_ID
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    say "Using CLOUDFLARE_API_TOKEN"
    wrangler whoami >/dev/null 2>&1 && { ok "auth ok (token)"; return; }
    warn "token present but whoami failed; falling back to login"
  }
  say "wrangler login flow (browser)"
  wrangler login >/dev/null 2>&1 && wrangler whoami >/dev/null 2>&1 || die "Authentication failed"
  ok "auth ok (login)"
}

ensure_worker_secrets(){
  say "Rotate OWNER_TOKEN + set ALLOWED_ORIGIN"
  OWNER_TOKEN="${OWNER_TOKEN:-$(rand_hex)}"
  printf %s "$OWNER_TOKEN" | wrangler secret put OWNER_TOKEN --name "$WORKER_NAME" >/dev/null || die "set OWNER_TOKEN failed"
  printf %s "$UI_URL" | wrangler secret put ALLOWED_ORIGIN --name "$WORKER_NAME" >/dev/null || warn "ALLOWED_ORIGIN secret failed; may already exist as a plain var"
  export OWNER_TOKEN
  if curl -fsS -H "X-Owner-Token: $OWNER_TOKEN" "$API_URL/debug/auth" | grep -qi '"ok"'; then ok "auth probe ok"; else warn "auth probe not ok (continuing)"; fi
}

ensure_d1_kv_r2(){
  say "Ensure D1/KV/R2"
  wrangler d1 create "$D1_NAME" >/dev/null 2>&1 || true
  wrangler kv namespace create "$KV_NAMESPACE" >/dev/null 2>&1 || true
  wrangler r2 bucket create "$R2_BUCKET" >/dev/null 2>&1 || true
  ok "resources ready"

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
  # WHY remote: avoids needing a local D1 binding in wrangler.toml
  wrangler d1 execute "$D1_NAME" --remote --file "$schema" >/dev/null
  rm -f "$schema"
  ok "D1 schema applied (remote)"
}

deploy_pages(){
  say "Deploy UI to Pages"
  if [[ ! -d "$REPO_DIR" ]]; then
    if [[ -n "$UI_GIT" ]]; then
      ensure_git; mkdir -p "$(dirname "$REPO_DIR")"
      git clone "$UI_GIT" "$REPO_DIR" || die "git clone failed"
      ok "UI repo cloned"
    else
      warn "REPO_DIR missing and UI_GIT not set; using current directory"
      REPO_DIR="$PWD"
    fi
  fi
  pushd "$REPO_DIR" >/dev/null || die "cd REPO_DIR failed"
  printf 'PUBLIC_API_BASE_URL=%s\n' "$API_URL" > .env.production

  local build_dir="."
  if [[ -f package.json ]] && grep -q '"build"' package.json; then
    (have npm && npm ci --prefer-offline || npm install)
    npm run build
    for d in dist build .output/public out; do [[ -d "$d" ]] && { build_dir="$d"; break; }; done
    ok "UI built ($build_dir)"
  else
    warn "no build script; deploying source"
  fi

  wrangler pages project create "$PAGES_PROJECT" --production-branch=main >/dev/null 2>&1 || true
  wrangler pages deploy "$build_dir" --project-name="$PAGES_PROJECT" --branch=main --commit-dirty=true >/dev/null
  popd >/dev/null
  ok "Pages deployed ($UI_URL)"
}

smoke_tests(){
  say "API smoke tests"
  curl -fsS "$API_URL/health" >/dev/null && ok "/health ok" || die "/health failed"
  curl -fsS -X POST "$API_URL/inventory" -H 'Content-Type: application/json' \
    -d '{"sku":"SKU-TEST","title":"Demo","category":"Shoes","cost_usd":12.50,"quantity":1}' >/dev/null && ok "create ok" || warn "create failed"
  local list_json id
  list_json="$(curl -fsS "$API_URL/inventory" || true)"
  id="$(printf '%s\n' "$list_json" | sed -n 's/.*"id":"\([^"]\+\)".*/\1/p' | head -n1 || true)"
  if [[ -n "$id" ]]; then
    ok "list ok (id $id)"
    curl -fsS -X PATCH -H "X-Owner-Token: $OWNER_TOKEN" -H 'Content-Type: application/json' \
      -d '{"status":"active","quantity":2}' "$API_URL/inventory/$id" >/dev/null && ok "patch ok" || warn "patch failed"
  else
    warn "list had no id; skipping patch"
  fi
}

main(){
  say "Pre-flight"; have curl || die "Need curl"
  ensure_node_npm
  ensure_wrangler
  ensure_cf_auth
  ensure_worker_secrets
  ensure_d1_kv_r2
  deploy_pages
  smoke_tests
  say "DONE ✅  Open $UI_URL, paste OWNER_TOKEN when prompted, then Load."
}
main "$@"
