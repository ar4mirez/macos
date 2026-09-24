# shellcheck shell=bash
# Interactive prompts that work under `curl | bash`, where stdin is the pipe.
# Answers are read from $MACOS_TTY (default /dev/tty) on fd 3; tests point it
# at a file of canned answers. With MACOS_YES=1 no prompt is shown: the
# default is used, and a prompt without one is an error. bash-3.2-safe.

: "${MACOS_YES:=0}"
: "${MACOS_TTY:=/dev/tty}"

_prompt_open() {
  if [ -z "${_MACOS_PROMPT_FD_OPEN:-}" ]; then
    # shellcheck disable=SC2261
    { exec 3<"$MACOS_TTY"; } 2>/dev/null || die "no terminal to prompt on; set MACOS_YES=1 and pass the needed options (e.g. --profile)"
    _MACOS_PROMPT_FD_OPEN=1
  fi
}

# ask <var> <question> [default] — free-text answer into <var>.
ask() {
  local _var="$1" _q="$2" _def="${3:-}" _ans=""
  if [ "$MACOS_YES" = 1 ]; then
    [ -n "$_def" ] || die "cannot answer '$_q' non-interactively; pass it as an option"
    printf -v "$_var" '%s' "$_def"
    return 0
  fi
  _prompt_open
  if [ -n "$_def" ]; then
    printf '%s [%s]: ' "$_q" "$_def" >&2
  else
    printf '%s: ' "$_q" >&2
  fi
  IFS= read -r _ans <&3 || true
  [ -n "$_ans" ] || _ans="$_def"
  [ -n "$_ans" ] || die "no answer given for '$_q'"
  printf -v "$_var" '%s' "$_ans"
}

# choose <var> <question> <option>... — numbered menu; first option is the
# default. Accepts the number or the option text.
choose() {
  local _var="$1" _q="$2" _ans="" _i _opt
  shift 2
  if [ "$MACOS_YES" = 1 ]; then
    printf -v "$_var" '%s' "$1"
    return 0
  fi
  _prompt_open
  printf '%s\n' "$_q" >&2
  _i=1
  for _opt in "$@"; do
    printf '  %d) %s\n' "$_i" "$_opt" >&2
    _i=$((_i + 1))
  done
  while :; do
    printf 'Choice [1]: ' >&2
    IFS= read -r _ans <&3 || die "no answer given for '$_q'"
    [ -n "$_ans" ] || _ans=1
    _i=1
    for _opt in "$@"; do
      if [ "$_ans" = "$_i" ] || [ "$_ans" = "$_opt" ]; then
        printf -v "$_var" '%s' "$_opt"
        return 0
      fi
      _i=$((_i + 1))
    done
    warn "not an option: $_ans"
  done
}

# confirm <question> — yes/no, default no. MACOS_YES=1 answers yes.
confirm() {
  local _ans=""
  [ "$MACOS_YES" = 1 ] && return 0
  _prompt_open
  printf '%s [y/N]: ' "$1" >&2
  IFS= read -r _ans <&3 || true
  case "$_ans" in y | Y | yes | YES) return 0 ;; esac
  return 1
}

# interactive <command...> — run a tool that needs a real terminal (e.g.
# `gh auth login`): stdin from $MACOS_TTY, output to the terminal rather than
# the log pipe. Honors --dry-run.
interactive() {
  if dry_run; then
    printf '  would run (interactive): %s\n' "$*" >&2
    return 0
  fi
  _prompt_open
  "$@" <&3 >&"${_MACOS_OUT_FD:-1}" 2>&"${_MACOS_ERR_FD:-2}"
}
