# shellcheck shell=bash
# Dry-run aware execution. Every mutation goes through these helpers so
# `--dry-run` (MACOS_DRY_RUN=1) can show exactly what would change.
# bash-3.2-safe. Requires lib/log.sh.

: "${MACOS_DRY_RUN:=0}"

dry_run() { [ "$MACOS_DRY_RUN" = 1 ]; }

# run <command...> — execute, or print it under --dry-run.
run() {
  if dry_run; then
    printf '  would run: %s\n' "$*" >&2
    return 0
  fi
  "$@"
}

# write_file <path> — write stdin to <path> (creating parent dirs), or show
# the content under --dry-run.
write_file() {
  local path="$1" content
  content="$(cat)"
  if dry_run; then
    printf '  would write %s:\n' "$path" >&2
    printf '%s\n' "$content" | sed 's/^/    | /' >&2
    return 0
  fi
  mkdir -p "$(dirname -- "$path")"
  printf '%s\n' "$content" >"$path"
}

# sudo_write_file <path> — like write_file, for root-owned files.
sudo_write_file() {
  local path="$1" content
  content="$(cat)"
  if dry_run; then
    printf '  would write (sudo) %s:\n' "$path" >&2
    printf '%s\n' "$content" | sed 's/^/    | /' >&2
    return 0
  fi
  printf '%s\n' "$content" | sudo tee "$path" >/dev/null
}
