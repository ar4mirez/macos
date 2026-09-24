# shellcheck shell=bash
# Resolves engine paths and loads machine-local settings. bash-3.2-safe.
#
# Precedence: variables already in the environment win over machine.env,
# which wins over the defaults below.

: "${MACOS_STATE:=${XDG_STATE_HOME:-$HOME/.local/state}/macos}"
MACOS_MACHINE_ENV="$MACOS_STATE/machine.env"

# Load KEY=value lines from machine.env without sourcing it, and only for
# keys the caller has not already set.
if [ -f "$MACOS_MACHINE_ENV" ]; then
  while IFS='=' read -r _k _v || [ -n "$_k" ]; do
    case "$_k" in
      '' | \#*) continue ;;
    esac
    if ! grep -Eq '^MACOS_[A-Z0-9_]+$' <<<"$_k"; then
      continue
    fi
    if [ -z "${!_k:-}" ]; then
      _v="${_v%\"}"
      _v="${_v#\"}"
      export "$_k=$_v"
    fi
  done <"$MACOS_MACHINE_ENV"
  unset _k _v
fi

: "${MACOS_DOTFILES:=$HOME/.dotfiles}"
# Where boot.sh installs the engine. `macos dev link` can point the `macos`
# command at a development clone instead; this stays the installed copy.
: "${MACOS_INSTALL_DIR:=$HOME/.local/share/macos}"
: "${MACOS_PROFILE:=}"
# Optional add-on profiles (e.g. "gaming"), space-separated; see lib/profile.sh.
: "${MACOS_ADDONS:=}"

export MACOS_STATE MACOS_MACHINE_ENV MACOS_DOTFILES MACOS_PROFILE MACOS_ADDONS MACOS_INSTALL_DIR

# machine_env_set <KEY> <value> — persist a MACOS_* setting for this machine,
# keeping the other keys. Needs lib/run.sh (dry-run) at call time.
machine_env_set() {
  local key="$1" val="$2" rest=""
  if [ -f "$MACOS_MACHINE_ENV" ]; then
    rest="$(grep -v "^$key=" "$MACOS_MACHINE_ENV" || true)"
    if grep -qxF "$key=\"$val\"" "$MACOS_MACHINE_ENV"; then
      return 0
    fi
  fi
  {
    [ -n "$rest" ] && printf '%s\n' "$rest"
    printf '%s="%s"\n' "$key" "$val"
  } | write_file "$MACOS_MACHINE_ENV"
  export "$key=$val"
}
