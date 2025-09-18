#!/usr/bin/env bash
set -euo pipefail
( command -v fuser >/dev/null 2>&1 && sudo fuser -k 8787/tcp 5173/tcp ) || true
pkill -f "wrangler dev" || true
pkill -f "vite" || true
echo "Stopped :8787 (API) and :5173 (UI)."
