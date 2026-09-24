# shellcheck shell=bash
# Logging helpers. All output goes to stderr so command stdout stays clean for
# piping. bash-3.2-safe.

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _C_BLUE=$'\033[34m' _C_GREEN=$'\033[32m' _C_YELLOW=$'\033[33m'
  _C_RED=$'\033[31m' _C_DIM=$'\033[2m' _C_RESET=$'\033[0m'
else
  _C_BLUE='' _C_GREEN='' _C_YELLOW='' _C_RED='' _C_DIM='' _C_RESET=''
fi

say()  { printf '%s==>%s %s\n' "$_C_BLUE" "$_C_RESET" "$*" >&2; }
ok()   { printf '%s ok%s %s\n' "$_C_GREEN" "$_C_RESET" "$*" >&2; }
skip() { printf '%s  -%s %s\n' "$_C_DIM" "$_C_RESET" "$*" >&2; }
warn() { printf '%s  !%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
die()  { printf '%s  x%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; exit 1; }

# log_to_file — mirror this process's stdout/stderr into a timestamped log
# under $MACOS_STATE/logs. Call once, near the start of a mutating command.
log_to_file() {
  local dir="$MACOS_STATE/logs"
  mkdir -p "$dir"
  MACOS_LOG="$dir/$(date +%Y%m%d-%H%M%S)-${0##*/}.log"
  export MACOS_LOG
  # Keep the real terminal on fds 4/5 for interactive tools (gh, sudo) that
  # refuse to prompt when stdout is a pipe.
  exec 4>&1 5>&2
  _MACOS_OUT_FD=4 _MACOS_ERR_FD=5
  exec > >(tee -a "$MACOS_LOG") 2> >(tee -a "$MACOS_LOG" >&2)
}
