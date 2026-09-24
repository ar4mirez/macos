# shellcheck shell=bash
# Authenticate sudo once and keep the timestamp fresh for the rest of the run,
# so .pkg casks and system changes don't prompt again mid-way. bash-3.2-safe.
# Requires lib/common.sh and lib/run.sh.

: "${MACOS_SUDO_REFRESH:=50}"

sudo_keepalive() {
  dry_run && return 0
  [ -n "${_MACOS_SUDO_PID:-}" ] && return 0
  if ! sudo -n true 2>/dev/null; then
    say "Administrator access is needed for system settings and .pkg installers."
    sudo -v || die "sudo authentication failed"
  fi
  (
    while kill -0 "$$" 2>/dev/null; do
      sudo -n true 2>/dev/null || exit 0
      sleep "$MACOS_SUDO_REFRESH"
    done
  ) &
  _MACOS_SUDO_PID=$!
  on_exit 'kill "$_MACOS_SUDO_PID" 2>/dev/null || true'
}

# sudo_preflight — fail before changing anything when sudo will be needed but
# cannot ask for a password (no terminal, e.g. an IDE or agent shell).
# sudo prompts on /dev/tty itself, regardless of stdin.
sudo_preflight() {
  dry_run && return 0
  sudo -n true 2>/dev/null && return 0
  (exec </dev/tty) 2>/dev/null && return 0
  die "administrator access is needed, but there is no terminal to type the password in. Run this from a terminal app (e.g. Terminal.app)."
}
