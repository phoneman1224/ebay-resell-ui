#!/usr/bin/env bash
# File: scripts/fix-perms.sh
# Purpose: Reset file ownership & permissions safely inside this repo.
# - Makes folders 755, scripts *.sh 755, most files 644
# - Secures secrets (.env*, *.pem, *.key) to 600
# - Optionally chowns everything to the invoking user
# Usage:
#   scripts/fix-perms.sh                 # default: repo root
#   scripts/fix-perms.sh ui worker       # limit to paths
#   scripts/fix-perms.sh --no-chown      # skip chown
#   sudo scripts/fix-perms.sh            # if you need ownership reset
#   scripts/fix-perms.sh --dry-run       # show what would change
#
# Notes:
# - Skips heavy/volatile dirs: .git, node_modules, .wrangler, dist, build, .cache
# - Safe on Linux/macOS. Requires: bash, find, xargs, chmod, chown

set -Eeuo pipefail
shopt -s nullglob

# ---------- config ----------
EXCLUDES=(.git node_modules .wrangler dist build .cache)
SECURE_GLOBS=(".env" ".env.*" "*.pem" "*.key" "id_rsa" "id_ed25519")
DEFAULT_PATHS=(.)

DO_CHOWN=1
DRY_RUN=0
PATHS=()

# ---------- parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-chown) DO_CHOWN=0; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  SHOW_HELP=1; shift ;;
    --)         shift; break ;;
    -*)         echo "Unknown flag: $1" >&2; exit 2 ;;
    *)          PATHS+=("$1"); shift ;;
  esac
done

[[ ${#PATHS[@]} -eq 0 ]] && PATHS=("${DEFAULT_PATHS[@]}")

if [[ "${SHOW_HELP:-0}" -eq 1 ]]; then
  sed -n '1,80p' "$0"
  exit 0
fi

# ---------- resolve repo root & user ----------
REPO_ROOT_DIR="${REPO_ROOT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT_DIR"

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_GROUP="$(id -gn "$TARGET_USER")"

# ---------- helpers ----------
log(){ printf "\033[0;34m%s\033[0m\n" "$1"; }
ok(){  printf "\033[0;32m✓ %s\033[0m\n" "$1"; }
warn(){printf "\033[1;33m! %s\033[0m\n" "$1"; }
err(){ printf "\033[0;31m✗ %s\033[0m\n" "$1"; }
run(){ if [[ $DRY_RUN -eq 1 ]]; then echo "+ $*"; else eval "$*"; fi }

# Build a -prune expression for find to skip excluded dirs
build_prune(){
  local expr="" first=1
  for d in "${EXCLUDES[@]}"; do
    if [[ $first -eq 1 ]]; then
      expr="-name $d"; first=0
    else
      expr="$expr -o -name $d"
    fi
  done
  printf '%s' "( $expr ) -prune -o"
}

PRUNE_EXPR=$(build_prune)

# ---------- chown (optional) ----------
if [[ $DO_CHOWN -eq 1 ]]; then
  log "Resetting ownership to $TARGET_USER:$TARGET_GROUP"
  for path in "${PATHS[@]}"; do
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "+ chown -R $TARGET_USER:$TARGET_GROUP $path"
    else
      chown -R "$TARGET_USER":"$TARGET_GROUP" "$path" 2>/dev/null || warn "Some files not owned (try sudo)"
    fi
  done
else
  warn "Skipping chown (--no-chown)"
fi

# ---------- directories 755 ----------
log "Setting directories to 755"
for path in "${PATHS[@]}"; do
  # shellcheck disable=SC2086
  run find "$path" $PRUNE_EXPR -type d -exec chmod 755 {} +
done

# ---------- scripts *.sh 755 ----------
log "Marking shell scripts executable (755)"
for path in "${PATHS[@]}"; do
  # shellcheck disable=SC2086
  run find "$path" $PRUNE_EXPR -type f -name "*.sh" -exec chmod 755 {} +
done

# ---------- general files 644 (non-exec) ----------
log "Setting regular files to 644 (non-exec)"
for path in "${PATHS[@]}"; do
  # shellcheck disable=SC2010,SC2086
  run find "$path" $PRUNE_EXPR -type f ! -perm -111 -exec chmod 644 {} +
done

# ---------- secure secrets to 600 ----------
log "Securing secrets to 600"
for glob in "${SECURE_GLOBS[@]}"; do
  for path in "${PATHS[@]}"; do
    # shellcheck disable=SC2086
    run find "$path" $PRUNE_EXPR -type f -name "$glob" -exec chmod 600 {} +
  done
done

ok "Permissions normalized"
log "Tip: run with --dry-run first to preview changes"
