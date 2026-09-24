# shellcheck shell=bash
# Process lock so two mutating runs never overlap. Uses mkdir, which is atomic.
# bash-3.2-safe. Requires lib/common.sh (on_exit, warn, die).

lock_acquire() { # lock_acquire [name]
  local dir pid
  dir="$MACOS_STATE/locks/${1:-macos}.lock"
  mkdir -p "$MACOS_STATE/locks"

  if ! mkdir "$dir" 2>/dev/null; then
    pid="$(cat "$dir/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      die "another macos run is in progress (pid $pid); lock: $dir"
    fi
    warn "removing stale lock left by pid ${pid:-unknown}"
    rm -rf "$dir"
    mkdir "$dir" || die "could not acquire lock: $dir"
  fi

  echo "$$" >"$dir/pid"
  MACOS_LOCK_DIR="$dir"
  on_exit lock_release
}

lock_release() {
  if [ -n "${MACOS_LOCK_DIR:-}" ] && [ -d "$MACOS_LOCK_DIR" ]; then
    rm -rf "$MACOS_LOCK_DIR"
  fi
  MACOS_LOCK_DIR=""
}
