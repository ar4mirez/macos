# shellcheck shell=bash
# Manual steps the engine cannot perform (GUI sign-ins, approvals). Stored in
# $MACOS_STATE/pending as `id|description` lines; `doctor` shows them as
# warnings. bash-3.2-safe. Requires lib/run.sh.

MACOS_PENDING="$MACOS_STATE/pending"

pending_add() { # pending_add <id> <description>
  if [ -f "$MACOS_PENDING" ] && grep -q "^$1|" "$MACOS_PENDING"; then
    return 0
  fi
  if dry_run; then
    printf '  would add pending step: %s\n' "$2" >&2
    return 0
  fi
  mkdir -p "$MACOS_STATE"
  printf '%s|%s\n' "$1" "$2" >>"$MACOS_PENDING"
}

pending_done() { # pending_done <id>
  [ -f "$MACOS_PENDING" ] || return 0
  dry_run && return 0
  grep -v "^$1|" "$MACOS_PENDING" >"$MACOS_PENDING.tmp" || true
  mv "$MACOS_PENDING.tmp" "$MACOS_PENDING"
}

pending_list() { # prints descriptions, one per line
  [ -f "$MACOS_PENDING" ] || return 0
  cut -d'|' -f2- "$MACOS_PENDING"
}
