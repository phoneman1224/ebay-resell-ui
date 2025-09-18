#!/usr/bin/env bash
# eBay Resell App – Autopilot (minimal, no-awk)
set -Eeuo pipefail

REPO_ROOT_DIR="${REPO_ROOT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
WORKER_DIR="$REPO_ROOT_DIR/worker"
UI_DIR="$REPO_ROOT_DIR/ui"
WRANGLER_TOML="$WORKER_DIR/wrangler.toml"

CMD="${1:-help}"; shift || true
D1_NAME="resellapp"; KV_BINDING="KV"; R2_BUCKET="resell-photos"
PAGES_URL=""; API_BASE=""; FORCE_CREATE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --d1-name) D1_NAME="$2"; shift 2 ;;
    --kv-binding) KV_BINDING="$2"; shift 2 ;;
    --r2-bucket) R2_BUCKET="$2"; shift 2 ;;
    --pages-url) PAGES_URL="$2"; shift 2 ;;
    --api-base) API_BASE="$2"; shift 2 ;;
    --force-create) FORCE_CREATE=1; shift ;;
    *) echo "Unknown flag: $1"; exit 2 ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
log(){ printf "%b%s%b\n" "$BLU" "$1" "$NC"; }
ok(){  printf "%b✓ %s%b\n" "$GREEN" "$1" "$NC"; }
warn(){printf "%b! %s%b\n" "$YEL" "$1" "$NC"; }
err(){ printf "%b✗ %s%b\n" "$RED" "$1" "$NC"; }
need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing: $1"; exit 1; }; }

need git; need node; need npm; need curl; need sed
command -v wrangler >/dev/null 2>&1 || { err "Install Wrangler: npm i -g wrangler@3"; exit 1; }
[[ -d "$WORKER_DIR" ]] || { err "Missing ./worker"; exit 1; }
[[ -f "$WRANGLER_TOML" ]] || { err "Missing $WRANGLER_TOML"; exit 1; }
[[ -d "$UI_DIR" ]] || mkdir -p "$UI_DIR"

wr_login(){ wrangler whoami >/dev/null 2>&1 && ok "Wrangler authenticated" || { warn "Login..."; wrangler login || { err "wrangler login failed"; exit 1; }; }; }

replace_or_placeholder(){ # $1 placeholder, $2 key, $3 val
  if grep -q "$1" "$WRANGLER_TOML"; then sed -i -E "s/${1//\//\\/}/$3/g" "$WRANGLER_TOML";
  else sed -i -E "s/^([[:space:]]*$2[[:space:]]*=[[:space:]]*\").*(\")/\1$3\2/" "$WRANGLER_TOML"; fi
}
set_key(){ sed -i -E "s/^([[:space:]]*$1[[:space:]]*=[[:space:]]*\").*(\")/\1$2\2/" "$WRANGLER_TOML" || true; }

create_d1(){ log "Ensuring D1: $D1_NAME"; local out id
  [[ $FORCE_CREATE -eq 1 ]] && wrangler d1 delete "$D1_NAME" >/dev/null 2>&1 || true
  out=$(wrangler d1 create "$D1_NAME" 2>&1 || true)
  echo "$out" | grep -Eq "Created|already exists" && ok "D1 exists" || { err "D1 create failed: $out"; exit 1; }
  id=$(wrangler d1 list 2>/dev/null | grep -E "\b$D1_NAME\b" -A1 | grep -Eo "[0-9a-f-]{36}" | head -n1 || true)
  [[ -n "$id" ]] && { replace_or_placeholder "__REPLACE_WITH_D1_ID__" "database_id" "$id"; set_key "database_name" "$D1_NAME"; ok "wrangler.toml D1 set"; } || warn "D1 id not parsed"
}
create_kv(){ log "Ensuring KV: $KV_BINDING"; local out id
  out=$(wrangler kv namespace create "$KV_BINDING" 2>&1 || true)
  [[ -z "$id" ]] && id=$(echo "$out" | grep -Eo "id: [A-Za-z0-9]+" | awk '{print $2}' | head -n1)
  [[ -z "$id" ]] && id=$(wrangler kv namespace list 2>/dev/null | grep -A1 "\b$KV_BINDING\b" | grep -Eo "[A-Za-z0-9]{32}" | head -n1 || true)
  [[ -n "$id" ]] && { replace_or_placeholder "__REPLACE_WITH_KV_ID__" "id" "$id"; ok "KV bound"; } || warn "KV id not found"
}
create_r2(){ log "Ensuring R2: $R2_BUCKET"; wrangler r2 bucket create "$R2_BUCKET" >/dev/null 2>&1 || true; set_key "bucket_name" "$R2_BUCKET"; ok "R2 bucket set"; }
put_secret(){ local key="$1" val="${2:-}"; [[ -z "$val" ]] && val=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n');
  printf "%s" "$val" | (cd "$WORKER_DIR" && wrangler secret put "$key" --stdin >/dev/null); ok "Secret $key set"; }

ensure_env(){ [[ -n "$PAGES_URL" ]] && { set_key "ALLOWED_ORIGIN" "$PAGES_URL"; ok "ALLOWED_ORIGIN -> $PAGES_URL"; }
  printf "PUBLIC_API_BASE_URL=%s\n" "${API_BASE:-http://127.0.0.1:8787}" > "$UI_DIR/.env"; ok "UI .env set"; }

ensure_ui(){ if [[ ! -f "$UI_DIR/package.json" ]]; then
  log "Scaffold ui/package.json"
  cat > "$UI_DIR/package.json" <<'JSON'
{ "name":"ebay-resell-ui","private":true,"version":"0.1.0","type":"module",
  "scripts":{"dev":"vite","build":"vite build","preview":"vite preview --port 5173"},
  "devDependencies":{"vite":"^5.4.0"} }
JSON
  [[ -f "$UI_DIR/index.html" ]] || cat > "$UI_DIR/index.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>eBay Resell UI</title></head>
<body><h1>eBay Resell UI</h1><p><button id="b">Check API</button> <span id="o"></span></p>
<script>document.getElementById('b').onclick=async()=>{const u=((window.PUBLIC_API_BASE_URL||'').replace(/\/$/,''))+'/api/health';const r=await fetch(u).catch(()=>({ok:false}));document.getElementById('o').textContent=r&&r.ok?'ok':'failed'};</script>
</body></html>
HTML
fi; }

install_deps(){ (cd "$WORKER_DIR" && npm i >/dev/null) && ok "Worker deps" || { err "Worker npm i failed"; exit 1; }
                (cd "$UI_DIR" && npm i >/dev/null) && ok "UI deps"     || { err "UI npm i failed"; exit 1; } }
migrate(){ (cd "$WORKER_DIR" && npm run migrate) || (cd "$WORKER_DIR" && wrangler d1 execute "$D1_NAME" --file ./schema.sql); ok "D1 migrated"; }
dev(){ log "Dev: Worker:8787 + UI:5173"; (cd "$WORKER_DIR" && wrangler dev --local --port 8787 >/tmp/wrangler-dev.log 2>&1 &) ; P=$!; trap 'kill $P 2>/dev/null||true' EXIT; sleep 1; (cd "$UI_DIR" && npm run dev); }

bootstrap(){ log "Bootstrap"; wr_login; ensure_ui; create_d1; create_kv; create_r2; put_secret OWNER_TOKEN ""; put_secret JWT_SECRET ""; put_secret ENCRYPTION_KEY ""; ensure_env; install_deps; migrate; ok "Done. Next: scripts/autopilot.sh dev"; }

case "$CMD" in
  help|--help|-h) sed -n '1,200p' "$0" ;;
  bootstrap)      bootstrap ;;
  dev)            dev ;;
  migrate)        migrate ;;
  *)              err "Unknown: $CMD"; sed -n '1,60p' "$0"; exit 2 ;;
esac
