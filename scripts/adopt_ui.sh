# Root Makefile for eBay Resell App
# Usage examples:
#   make doctor
#   make dev           # run API (8787) and UI (5173) locally
#   make migrate       # apply D1 schema
#   make deploy-api    # wrangler deploy worker
#   make build-ui      # vite build

SHELL := /bin/bash
REPO_ROOT := $(shell git rev-parse --show-toplevel 2>/dev/null || pwd)
WORKER := $(REPO_ROOT)/worker
UI := $(REPO_ROOT)/ui

.PHONY: help doctor install migrate dev dev-api dev-ui stop build-ui deploy-api pages-hint clean

help:
	@echo "Targets: doctor install migrate dev dev-api dev-ui stop build-ui deploy-api pages-hint clean"

# --- Diagnostics ---
doctor:
	@chmod +x scripts/doctor.sh || true
	@scripts/doctor.sh

# --- Install deps ---
install:
	@cd $(WORKER) && npm i
	@cd $(UI) && npm i

# --- Database migration ---
migrate:
	@cd $(WORKER) && wrangler d1 execute $$(grep -E '^\s*database_name\s*=\s*"' wrangler.toml | sed -E 's/.*"(.*)"/\1/' | head -n1) --file=./schema.sql

# --- Dev servers ---
dev-api:
	@cd $(WORKER) && wrangler dev --local --port 8787

dev-ui:
	@cd $(UI) && echo "PUBLIC_API_BASE_URL?=$${PUBLIC_API_BASE_URL:-http://127.0.0.1:8787}" && npm run dev

# Runs both API and UI; Ctrl+C to stop
# Tip: use two terminals for better logs.
dev:
	@$(MAKE) -j2 dev-api dev-ui

stop:
	@pkill -f "wrangler dev --local --port 8787" || true

# --- Build & Deploy ---
build-ui:
	@cd $(UI) && npm run build

deploy-api:
	@cd $(WORKER) && wrangler deploy

# Cloudflare Pages is configured via dashboard; this prints a brief hint.
pages-hint:
	@echo "To deploy UI to Cloudflare Pages:" \
	&& echo "  1) Framework preset: Vite" \
	&& echo "  2) Build command: npm run build" \
	&& echo "  3) Build output directory: dist" \
	&& echo "  4) Set env var PUBLIC_API_BASE_URL to your Worker URL"

clean:
	@rm -rf $(UI)/node_modules $(UI)/dist $(WORKER)/node_modules
