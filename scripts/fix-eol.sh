#!/usr/bin/env bash
set -Eeuo pipefail; shopt -s nullglob
is_text(){ file -b --mime "$1" 2>/dev/null | grep -qiE 'text|utf-8|json|xml|yaml|toml|javascript|typescript|shell'; }
fix_file(){ local f="$1"; [[ -f "$f" ]] || return 0; is_text "$f" || return 0; sed -i 's/\r$//' "$f" || true;
  if head -c 3 "$f" 2>/dev/null | od -An -t x1 | tr -d ' \n' | grep -qi '^efbbbf$'; then tail -c +4 "$f" > "$f.tmp" && mv "$f.tmp" "$f"; fi; }
walk(){ for p in "$@"; do if [[ -d "$p" ]]; then while IFS= read -r -d '' f; do fix_file "$f"; done < <(find "$p" -type f -print0); else fix_file "$p"; fi; done; }
[[ $# -eq 0 ]] && { echo "Usage: $0 <files/dirs...>" >&2; exit 2; }; walk "$@"; echo "EOL/BOM normalization complete."
