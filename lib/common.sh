# shellcheck shell=bash
# Shared prelude for every engine script. Must stay bash-3.2-safe: bootstrap
# sources it before Homebrew bash exists.

set -Eeuo pipefail

if [ -z "${MACOS_ROOT:-}" ]; then
  MACOS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fi
export MACOS_ROOT

# shellcheck source=lib/env.sh
. "$MACOS_ROOT/lib/env.sh"
# shellcheck source=lib/log.sh
. "$MACOS_ROOT/lib/log.sh"
# shellcheck source=lib/sys.sh
. "$MACOS_ROOT/lib/sys.sh"

# One EXIT trap for the whole process; libraries register cleanups here
# instead of overwriting each other's traps.
_MACOS_EXIT_HOOKS=""

on_exit() { # on_exit <command string>
  _MACOS_EXIT_HOOKS="$1${_MACOS_EXIT_HOOKS:+; $_MACOS_EXIT_HOOKS}"
}

# The process keeps its original exit status; this must never fail itself,
# or the ERR trap would report a bogus error.
_macos_run_exit_hooks() {
  trap - ERR
  if [ -n "$_MACOS_EXIT_HOOKS" ]; then
    eval "$_MACOS_EXIT_HOOKS" || true
  fi
}

# Report the first failure only: with errtrace the trap fires again in every
# calling function as the error unwinds, and in command substitutions.
_macos_on_err() {
  local rc=$?
  # Inside $(...) a failure may be expected (e.g. reading a missing file);
  # if it matters, it propagates and the main shell reports it.
  if [ -z "${_MACOS_ERR_REPORTED:-}" ] && [ "${BASH_SUBSHELL:-0}" -eq 0 ]; then
    _MACOS_ERR_REPORTED=1
    warn "failed (exit $rc) during: ${MACOS_STEP:-${0##*/}} [${BASH_SOURCE[1]:-?}:${BASH_LINENO[0]:-?}]"
  fi
  return "$rc"
}

trap _macos_run_exit_hooks EXIT
trap _macos_on_err ERR

# step <description> — names the unit of work for logs and error reports.
step() {
  MACOS_STEP="$*"
  say "$*"
}

# not_implemented <phase> — placeholder body for commands still being built.
not_implemented() {
  warn "'macos ${0##*/macos-}' is not implemented yet (planned for phase $1)."
  exit 2
}
