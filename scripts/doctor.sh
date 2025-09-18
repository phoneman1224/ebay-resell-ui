#!/usr/bin/env bash
# File: scripts/doctor.sh
# Usage: ./scripts/doctor.sh [--prod] [--fast] [--debug]
set -Eeuo pipefail; shopt -s lastpipe

# --- flags ---
PROD=0; FAST=0; DEBUG=0
for a in "$@"; do case "$a" in --prod) PROD=1;; --fast) FAST=1;; --debug) DEBUG=1;; esac; done

# --- paths ---
REPO_ROOT_DIR="${REPO_ROOT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
WORKER_DIR="$REPO_ROOT_DIR/worker"
UI_DIR="$REPO_ROOT_DIR/ui"
WRANGLER_TOML="$WORKER_DIR/wrangler.toml"

# --- ui helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
pass(){ printf "%b✓ %s%b\n" "$GREEN" "$1" "$NC"; }
warn(){ printf "%b! %s%b\n" "$YELLOW" "$1" "$NC"; }
fail(){ printf "%b✗ %s%b\n" "$RED" "$1" "$NC"; }
info(){ printf "%b%s%b\n" "$BLUE" "$1" "$NC"; }
section(){ printf "\n%b%s%b\n" "$BOLD" "$1" "$NC"; }

FAILED=0
check(){ local msg="$1"; shift; if "$@"; then pass "$msg"; else fail "$msg"; FAILED=1; fi }
exists(){ command -v "$1" >/dev/null 2>&1; }
semver_ge(){ local a; a=$(printf '%s\n%s\n' "$1" "$2" | tr -d 'v' | sort -V | tail -n1); [[ "$a" == "${1#v}" ]]; }

# --- banner ---
section "Doctor starting"
info "Repo: $REPO_ROOT_DIR"
[[ $DEBUG -eq 1 ]] && info "Flags => PROD=$PROD FAST=$FAST DEBUG=$DEBUG"

# --- Environment ---
section "Environment"
check "POSIX shell (Linux/macOS)" bash -c '[[ $(uname -s) =~ (Linux|Darwin) ]]'
check "git installed" exists git
check "node installed" exists node
NODE_V=$(node -v 2>/dev/null || echo "v0.0.0"); info "Node.js: $NODE_V"
semver_ge "$NODE_V" v18.18.0 && pass "Node >= 18.18" || warn "Node >= 20 recommended"
check "npm installed" exists npm

# --- Wrangler ---
section "Cloudflare Wrangler"
check "wrangler installed" exists wrangler
if exists wrangler; then
  WRANGLER_V=$(wrangler --version 2>/dev/null | awk '{print $NF}' || echo "0.0.0"); info "Wrangler: $WRANGLER_V"
  wrangler whoami >/dev/null 2>&1 && pass "Authenticated (wrangler whoami)" || warn "Not logged in. Run: wrangler login"
fi
check "worker dir exists" bash -c "[ -d '$WORKER_DIR' ]"
check "wrangler.toml present" bash -c "[ -f '$WRANGLER_TOML' ]"

# --- wrangler.toml sanity ---
D1_NAME=""
if [[ -f "$WRANGLER_TOML" ]]; then
  grep -q "__REPLACE_WITH_D1_ID__" "$WRANGLER_TOML" && warn "D1 database_id placeholder still set"
  grep -q "__REPLACE_WITH_KV_ID__" "$WRANGLER_TOML" && warn "KV id placeholder still set"
  D1_NAME=$(grep -E '^database_name\s*=\s*"' "$WRANGLER_TOML" | sed -E 's/.*=\s*"(.*)"/\1/' | head -n1 || true)
  [[ -n "$D1_NAME" ]] && info "D1 database_name: $D1_NAME" || warn "D1 database_name not found"
  grep -q 'binding = "R2"' "$WRANGLER_TOML" && pass "R2 binding present" || warn "R2 binding missing"
  grep -q 'binding = "KV"' "$WRANGLER_TOML" && pass "KV binding present" || warn "KV binding missing"
  if [[ $PROD -eq 1 ]] && grep -q 'ALLOWED_ORIGIN.*= "\*"' "$WRANGLER_TOML"; then fail "ALLOWED_ORIGIN is '*' in prod"; FAILED=1; fi
fi

# --- Secrets ---
section "Wrangler Secrets"
if exists wrangler && [[ -d "$WORKER_DIR" ]]; then
  SECRET_LIST=$( (cd "$WORKER_DIR" && wrangler secret list 2>/dev/null) || true )
  for s in OWNER_TOKEN JWT_SECRET ENCRYPTION_KEY; do
    if echo "$SECRET_LIST" | grep -q "$s"; then pass "Secret $s set"; else warn "Secret $s missing"; fi
  done
fi

# --- D1 quick check ---
section "D1 quick check"
if [[ -n "$D1_NAME" ]]; then
  if wrangler d1 execute "$D1_NAME" --local --command "SELECT 1;" >/dev/null 2>&1; then
    pass "D1 local responds"
  elif wrangler whoami >/dev/null 2>&1 && wrangler d1 execute "$D1_NAME" --command "SELECT 1;" >/dev/null 2>&1; then
    pass "D1 remote responds"
  else
    warn "D1 check failed"
  fi
else
  warn "Skip D1 check – no database_name in wrangler.toml"
fi

# --- Worker dev smoke (skippable) ---
section "Worker dev smoke"
if [[ $FAST -eq 1 ]]; then
  warn "--fast: skipping dev smoke"
else
  if exists curl && [[ -d "$WORKER_DIR" ]]; then
    (cd "$WORKER_DIR" && (
      wrangler dev --local --port 8787 >/tmp/wrangler-dev.log 2>&1 &
      DEV_PID=$!
      trap 'kill $DEV_PID 2>/dev/null || true' EXIT
      for i in {1..25}; do sleep 0.2; if curl -sfS http://127.0.0.1:8787/api/health >/dev/null; then READY=1; break; fi; done
      if [[ "${READY:-0}" -eq 1 ]]; then pass "/api/health reachable"; else fail "Worker dev did not start"; FAILED=1; fi
    ))
  else
    warn "curl not found or worker dir missing"
  fi
fi

# --- UI build (skippable) ---
section "UI build"
if [[ -d "$UI_DIR" ]]; then
  if [[ -f "$UI_DIR/.env" ]] || [[ -f "$UI_DIR/.env.local" ]]; then
    API_BASE=$(grep -E '^PUBLIC_API_BASE_URL=' "$UI_DIR"/.env* 2>/dev/null | tail -n1 | sed 's/^[^=]*=//')
    [[ -n "${API_BASE:-}" ]] && pass "PUBLIC_API_BASE_URL set ($API_BASE)" || warn "PUBLIC_API_BASE_URL blank"
  else
    warn "UI .env not found"
  fi
  if [[ $FAST -eq 1 ]]; then
    warn "--fast: skipping UI install/build"
  else
    (cd "$UI_DIR" && npm -s ci || npm -s i) && pass "UI deps installed" || { fail "UI deps install failed"; FAILED=1; }
    (cd "$UI_DIR" && npm run -s build) && pass "UI build OK" || { fail "UI build failed"; FAILED=1; }
    [[ -f "$UI_DIR/dist/index.html" ]] && pass "dist/index.html present" || { fail "dist output missing"; FAILED=1; }
  fi
else
  warn "UI directory missing"
fi

# --- Git / GitHub ---
section "Git / GitHub"
check "inside git repo" git rev-parse --is-inside-work-tree
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD || echo "?"); info "Branch: $BRANCH"
  git remote get-url origin >/dev/null 2>&1 && pass "origin remote configured" || warn "No origin remote"
  git status --porcelain | grep -q . && warn "Uncommitted changes present" || pass "Working tree clean"
  [[ -d "$REPO_ROOT_DIR/.github/workflows" ]] && pass "CI workflows present" || warn "No GitHub Actions workflows"
fi
if exists gh; then
  gh --version >/dev/null 2>&1 && pass "GitHub CLI installed"
  gh auth status >/dev/null 2>&1 && pass "GitHub auth OK" || warn "Run: gh auth login"
  if git remote get-url origin >/dev/null 2>&1; then
    gh repo view >/dev/null 2>&1 && pass "GitHub repo accessible" || warn "Unable to view repo via gh"
  fi
else
  warn "GitHub CLI not installed (optional)"
fi

# --- Summary ---
section "Summary"
if [[ $FAILED -eq 0 ]]; then
  printf "%bAll core checks passed. You're good to go.✅%b\n" "$GREEN" "$NC"; exit 0
else
  printf "%bSome checks failed. See messages above.❌%b\n" "$RED" "$NC"; exit 1
fi
