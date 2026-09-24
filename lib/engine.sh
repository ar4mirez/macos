# shellcheck shell=bash
# The engine itself: migrations, the `macos` command on PATH, self-update.
# bash-3.2-safe. Requires lib/common.sh and lib/run.sh.

: "${MACOS_MIGRATIONS_DIR:=$MACOS_ROOT/migrations}"
MIGRATIONS_STATE="$MACOS_STATE/migrations"
MACOS_CLI_LINK="$HOME/.local/bin/macos"

# --- migrations --------------------------------------------------------------
#
# migrations/<unix-timestamp>.sh are one-shot fixes for Macs set up by an
# older engine (renamed files, moved state, ...). Each runs once, in order,
# with `bash -Eeuo pipefail`, stdin closed and MACOS_* exported; a marker in
# state/migrations/ records it. A fresh bootstrap marks them all done, since
# a new Mac never had the old layout.

migrations_all() {
  [ -d "$MACOS_MIGRATIONS_DIR" ] || return 0
  find "$MACOS_MIGRATIONS_DIR" -maxdepth 1 -name '[0-9]*.sh' -exec basename {} \; | sort -n
}

migrations_pending() {
  local m
  for m in $(migrations_all); do
    [ -f "$MIGRATIONS_STATE/${m%.sh}" ] || echo "$m"
  done
}

migrations_mark_all() {
  local m
  run mkdir -p "$MIGRATIONS_STATE"
  for m in $(migrations_all); do
    run touch "$MIGRATIONS_STATE/${m%.sh}"
  done
  ok "fresh install: $(migrations_all | wc -l | tr -d ' ') migration(s) marked as already applied"
}

migrations_run() {
  local m pending
  pending="$(migrations_pending)"
  if [ -z "$pending" ]; then
    skip "no pending migrations"
    return 0
  fi
  run mkdir -p "$MIGRATIONS_STATE"
  for m in $pending; do
    say "Migration $m"
    if dry_run; then
      printf '  would run: %s\n' "$MACOS_MIGRATIONS_DIR/$m" >&2
      continue
    fi
    if ! bash -Eeuo pipefail "$MACOS_MIGRATIONS_DIR/$m" </dev/null; then
      die "migration $m failed; fix the cause and re-run 'macos update' (later migrations were not run)"
    fi
    touch "$MIGRATIONS_STATE/${m%.sh}"
    ok "migration $m applied"
  done
}

# --- CLI on PATH -------------------------------------------------------------

# engine_cli_linked — ~/.local/bin/macos points at this engine (resolved, so
# /var vs /private/var and other symlinked prefixes compare equal).
engine_cli_linked() {
  [ -L "$MACOS_CLI_LINK" ] && [ "$(readlink -f "$MACOS_CLI_LINK" 2>/dev/null)" = "$(readlink -f "$MACOS_ROOT/bin/macos")" ]
}

engine_link_cli() {
  if engine_cli_linked; then
    skip "'macos' already on PATH (~/.local/bin/macos)"
    return 0
  fi
  if [ -e "$MACOS_CLI_LINK" ] && [ ! -L "$MACOS_CLI_LINK" ]; then
    warn "not linking the macos command: ~/.local/bin/macos exists and is not ours"
    return 0
  fi
  run mkdir -p "$(dirname "$MACOS_CLI_LINK")"
  run ln -sfn "$MACOS_ROOT/bin/macos" "$MACOS_CLI_LINK"
  ok "'macos' command linked into ~/.local/bin"
}

# --- self-removal guard ------------------------------------------------------

# engine_removable — only ever delete a directory that is plainly an engine
# clone, never whatever MACOS_ROOT happens to be set to.
engine_removable() {
  [ -d "$MACOS_ROOT/.git" ] && [ -x "$MACOS_ROOT/bin/macos" ] && [ -f "$MACOS_ROOT/lib/engine.sh" ] &&
    case "$MACOS_ROOT" in "$HOME" | "$HOME/" | / | "") return 1 ;; esac
}
