#!/usr/bin/env bash
set -euo pipefail
ROOT="$(pwd)"
WORKER="$ROOT/worker"
UI="$ROOT/ui"

# predictable token / CORS
mkdir -p "$WORKER"
cat > "$WORKER/.dev.vars" <<'VARS'
OWNER_TOKEN="change-me"
ALLOWED_ORIGIN="*"
VARS

# kill anything on our ports
( command -v fuser >/dev/null 2>&1 && sudo fuser -k 8787/tcp 5173/tcp ) || true
pkill -f "wrangler dev" || true
pkill -f "vite" || true

# start API with wrangler v4 and our dev config
( cd "$WORKER" && npx -y wrangler@4 dev -c wrangler.dev.jsonc --port 8787 >"$ROOT/worker.log" 2>&1 & )

# start UI from inside ui/ using proxy config
( cd "$UI" && npm install --silent >/dev/null 2>&1 \
  && nohup npx vite --config vite.config.ts --host 127.0.0.1 --port 5173 >"$ROOT/ui.log" 2>&1 & )

sleep 2
echo "UI : http://127.0.0.1:5173/    (Quick Test at /quicktest.html)"
echo "API: http://127.0.0.1:8787/api"
echo "Token: change-me"
echo "Logs: $ROOT/worker.log | $ROOT/ui.log"
