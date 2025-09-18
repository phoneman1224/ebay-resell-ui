SHELL := /usr/bin/env bash
ROOT := $(shell git rev-parse --show-toplevel 2>/dev/null || pwd)
.RECIPEPREFIX := >

.PHONY: help doctor-fast dev stop logs

help:
> @echo "Targets:"
> @echo "  make doctor-fast  - quick diagnostics"
> @echo "  make dev          - start Worker (:8787) + UI (:5173) (keeps running)"
> @echo "  make logs         - tail recent logs for both"
> @echo "  make stop         - stop local dev servers"

doctor-fast:
> @if [ -x "$(ROOT)/scripts/doctor.sh" ]; then \
>   "$(ROOT)/scripts/doctor.sh" --fast --debug || true; \
> else \
>   echo "scripts/doctor.sh not found (skipping)"; \
> fi

dev:
> @mkdir -p /tmp
> @pkill -f "wrangler dev" 2>/dev/null || true
> @pkill -f "vite" 2>/dev/null || true
> @nohup bash -lc 'cd "$(ROOT)/worker" && wrangler dev --local --port 8787' >/tmp/wrangler-dev.log 2>&1 &
> @sleep 1
> @nohup bash -lc 'cd "$(ROOT)/ui" && npm run dev' >/tmp/ui-dev.log 2>&1 &
> @sleep 1
> @echo "API: http://127.0.0.1:8787   |   UI: http://127.0.0.1:5173"
> @echo "Use: make logs   (to view tails)   |   make stop   (to stop)"

logs:
> @echo "---- Wrangler (/tmp/wrangler-dev.log) ----"
> @tail -n 40 /tmp/wrangler-dev.log || true
> @echo
> @echo "---- UI (/tmp/ui-dev.log) ----"
> @tail -n 40 /tmp/ui-dev.log || true
> @echo

stop:
> @pkill -f "wrangler dev" 2>/dev/null || true
> @pkill -f "vite" 2>/dev/null || true
> @echo "Stopped local dev."
