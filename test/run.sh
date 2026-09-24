#!/bin/bash
# Test suite. Runs under /bin/bash 3.2 on purpose: the bootstrap path must too.
#
# Isolation: HOME, MACOS_STATE and MACOS_DOTFILES point into a temp sandbox,
# and every system-mutating tool is replaced by test/stubs/stub on PATH.
# `defaults` ignores $HOME (cfprefsd resolves the real user), so the stubs —
# not the HOME redirect — are what keep tests off the real machine.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/macos-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

STUBBED_TOOLS="defaults killall osascript scutil sudo brew mas dockutil duti softwareupdate hidutil pmset gh op git curl xcode-select uname mise open ssh-add fdesetup csrutil ssh lipo"

REAL_HOME="$HOME"
export HOME="$SANDBOX/home"
export MACOS_STATE="$SANDBOX/state"
export MACOS_DOTFILES="$SANDBOX/dotfiles"
export STUB_LOG="$SANDBOX/stub.log"
export NO_COLOR=1
# The user's shell exports XDG_* (and maybe GIT_CONFIG_*): real tools in the
# tests (git, stow) must only ever see the sandbox HOME.
unset XDG_STATE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
unset MACOS_PROFILE MACOS_BASH
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$SANDBOX/bin"

for t in $STUBBED_TOOLS; do
  ln -s "$ROOT/test/stubs/stub" "$SANDBOX/bin/$t"
done
export PATH="$SANDBOX/bin:$PATH"
for t in socketfilterfw activateSettings op-ssh-sign; do
  ln -s "$ROOT/test/stubs/stub" "$SANDBOX/bin/$t"
done
export SOCKETFILTERFW="$SANDBOX/bin/socketfilterfw"
export ACTIVATE_SETTINGS="$SANDBOX/bin/activateSettings"
export OP_SSH_SIGN="$SANDBOX/bin/op-ssh-sign"
# `defaults` gets a stateful double so idempotency and read-back are testable.
ln -sf "$ROOT/test/stubs/defaults" "$SANDBOX/bin/defaults"
export STUB_DEFAULTS_DB="$SANDBOX/defaults.db"
export MANAGED_PREFS_DIR="$SANDBOX/managed"
export MACOS_MIGRATIONS_DIR="$SANDBOX/migrations"
ln -s "$ROOT/test/stubs/stub" "$SANDBOX/bin/tailscale-cli"
export TAILSCALE_CLI="$SANDBOX/bin/tailscale-cli"
export PAM_SUDO_LOCAL="$SANDBOX/etc/sudo_local"
export HOMEBREW_PREFIX="$SANDBOX/homebrew"
export MACOS_SUDO_REFRESH=1
mkdir -p "$SANDBOX/etc" "$HOMEBREW_PREFIX/bin"
ln -s "$ROOT/test/stubs/stub" "$HOMEBREW_PREFIX/bin/brew"

# Guard 1: refuse to run at all unless the stubs win PATH resolution.
for t in $STUBBED_TOOLS; do
  if [ "$(command -v "$t")" != "$SANDBOX/bin/$t" ]; then
    echo "FATAL: $t does not resolve to its stub; refusing to run tests" >&2
    exit 1
  fi
done

pass=0
fail=0
failed=""

# check <name> <command...> — passes when the command exits 0.
check() {
  local name="$1"
  shift
  if ("$@") >"$SANDBOX/out" 2>&1; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    failed="$failed\n  - $name"
    printf '  FAIL %s\n' "$name"
    sed 's/^/       | /' "$SANDBOX/out"
  fi
}

section() { printf '\n%s\n' "$*"; }

BASH4="$(for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [ -x "$b" ] && echo "$b" && break; done)"
ENGINE_SH="$(ls "$ROOT"/bin/macos "$ROOT"/lib/*.sh "$ROOT"/libexec/macos-* "$ROOT"/test/run.sh "$ROOT"/test/stubs/stub "$ROOT"/boot.sh 2>/dev/null)"

# ---------------------------------------------------------------------------
section "Syntax"

bash32_files() {
  local f
  for f in "$ROOT"/bin/macos "$ROOT"/lib/*.sh "$ROOT"/test/run.sh "$ROOT"/test/stubs/stub "$ROOT"/boot.sh; do
    [ -f "$f" ] && echo "$f"
  done
  for f in "$ROOT"/libexec/macos-*; do
    grep -q '^# macos:bash=3$' "$f" && echo "$f"
  done
}

t_syntax_bash32() {
  local f rc=0
  for f in $(bash32_files); do
    /bin/bash -n "$f" || { echo "bash 3.2 syntax error: $f"; rc=1; }
  done
  return "$rc"
}
check "bootstrap-path files parse under /bin/bash 3.2" t_syntax_bash32

t_syntax_all() {
  local f rc=0 b="${BASH4:-/bin/bash}"
  for f in $ENGINE_SH "$ROOT"/migrations/*.sh; do
    [ -f "$f" ] || continue
    "$b" -n "$f" || { echo "syntax error: $f"; rc=1; }
  done
  return "$rc"
}
check "all scripts parse" t_syntax_all

t_shellcheck() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck not installed (skipped locally, enforced in CI)"
    [ -z "${CI:-}" ]
    return
  fi
  # shellcheck disable=SC2086
  shellcheck -x -P "$ROOT" --severity=warning $ENGINE_SH
}
check "shellcheck --severity=warning" t_shellcheck

# ---------------------------------------------------------------------------
section "Safety guards"

t_no_absolute_system_tools() {
  # Absolute paths would bypass the PATH stubs and hit the real machine.
  # Tools that only exist off-PATH are named once, in lib/sys.sh.
  ! grep -nE '/usr/bin/(defaults|killall|osascript|sudo)|/usr/sbin/(scutil|softwareupdate)|ApplicationFirewall/|activateSettings$|Resources/activateSettings|op-ssh-sign' \
    $ENGINE_SH | grep -vE '^[^:]*(test/run\.sh|lib/sys\.sh):'
}
check "no absolute paths to system tools outside lib/sys.sh" t_no_absolute_system_tools

t_sys_overridable() {
  (
    SOCKETFILTERFW="$SANDBOX/bin/sudo" ACTIVATE_SETTINGS="$SANDBOX/bin/sudo" OP_SSH_SIGN="$SANDBOX/bin/sudo"
    . "$ROOT/lib/sys.sh"
    [ "$SOCKETFILTERFW" = "$SANDBOX/bin/sudo" ] && [ "$ACTIVATE_SETTINGS" = "$SANDBOX/bin/sudo" ] && [ "$OP_SSH_SIGN" = "$SANDBOX/bin/sudo" ]
  )
}
check "off-PATH tool paths in lib/sys.sh are overridable" t_sys_overridable

t_stub_records() {
  : >"$STUB_LOG"
  defaults write -g KeyRepeat -int 2
  grep -qx 'defaults write -g KeyRepeat -int 2' "$STUB_LOG"
}
check "defaults is stubbed and recorded" t_stub_records

t_stub_defaults_read_missing() { ! defaults read -g Nope; }
check "stubbed 'defaults read' reports a missing key by default" t_stub_defaults_read_missing

# ---------------------------------------------------------------------------
section "Dispatcher"

M="$ROOT/bin/macos"

t_help() { "$M" help >"$SANDBOX/o" && grep -q '^  apply ' "$SANDBOX/o"; }
check "help lists commands" t_help

t_noargs_help() { "$M" >"$SANDBOX/o" && grep -q 'Usage: macos <command>' "$SANDBOX/o"; }
check "no args prints usage" t_noargs_help

t_version() { [ "$("$M" --version)" = "$(cat "$ROOT/version")" ]; }
check "--version prints the version file" t_version

t_unknown() {
  local rc=0
  "$M" definitely-not-a-command >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 127 ]
}
check "unknown command exits 127" t_unknown

t_sub_help() { "$M" apply --help >"$SANDBOX/o" && grep -q '^Usage: macos apply' "$SANDBOX/o"; }
check "subcommand --help prints usage" t_sub_help

t_metadata() {
  local f rc=0
  for f in "$ROOT"/libexec/macos-*; do
    grep -q '^# macos:summary=.' "$f" || { echo "missing summary: $f"; rc=1; }
    grep -q '^# macos:usage=macos ' "$f" || { echo "missing usage: $f"; rc=1; }
    [ -x "$f" ] || { echo "not executable: $f"; rc=1; }
  done
  return "$rc"
}
check "every subcommand has summary, usage and +x" t_metadata

t_symlinked() {
  ln -s "$M" "$SANDBOX/bin/macos-link"
  "$SANDBOX/bin/macos-link" --version >/dev/null
}
check "works when invoked through a symlink" t_symlinked

t_bootstrap_runs_on_bash32() {
  # bootstrap declares bash=3, so it is exec'd with /bin/bash even when no
  # bash 4 exists; it reports the version it runs under in dry-run mode.
  rm -rf "$MACOS_STATE"
  MACOS_BASH=/nonexistent STUB_GH_OUT="Token scopes: 'admin:public_key', 'admin:ssh_signing_key'" \
    "$M" bootstrap --yes --dry-run --profile base --hostname x >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q 'under bash 3\.' "$SANDBOX/o"
}
check "bootstrap is dispatched under bash 3.2" t_bootstrap_runs_on_bash32

t_bash4_override() {
  [ -n "$BASH4" ] || { echo "no bash 4 available"; return 0; }
  local rc=0
  MACOS_BASH="$BASH4" "$M" apply --frobnicate >"$SANDBOX/o" 2>&1 || rc=$?
  # Reaching the subcommand's own argument check proves it ran under bash 4.
  [ "$rc" -eq 1 ] && grep -q "unknown option: --frobnicate" "$SANDBOX/o"
}
check "bash-4 subcommands run under MACOS_BASH" t_bash4_override

# ---------------------------------------------------------------------------
section "Libraries"

t_env_machine_env() {
  mkdir -p "$MACOS_STATE"
  printf '# comment\nMACOS_PROFILE=work\nMACOS_HOSTNAME="studio"\nNOT_OURS=1\n' >"$MACOS_STATE/machine.env"
  (
    unset MACOS_PROFILE
    . "$ROOT/lib/env.sh"
    [ "$MACOS_PROFILE" = work ] && [ "$MACOS_HOSTNAME" = studio ] && [ -z "${NOT_OURS:-}" ]
  )
}
check "env.sh loads MACOS_* keys from machine.env" t_env_machine_env

t_machine_env_literal() {
  mkdir -p "$MACOS_STATE"
  printf 'MACOS_HOSTNAME="a-b"\n' >"$MACOS_STATE/machine.env"
  /bin/bash -c '. "$1/lib/common.sh"; . "$1/lib/run.sh"; machine_env_set MACOS_HOSTNAME a.b' _ "$ROOT" 2>/dev/null
  grep -qxF 'MACOS_HOSTNAME="a.b"' "$MACOS_STATE/machine.env"
}
check "machine_env_set compares values literally (a.b is not a-b)" t_machine_env_literal

t_env_precedence() {
  (
    export MACOS_PROFILE=personal
    . "$ROOT/lib/env.sh"
    [ "$MACOS_PROFILE" = personal ]
  )
}
check "environment wins over machine.env" t_env_precedence

t_log_no_color() {
  local out
  out="$(MACOS_DRY_RUN=0; . "$ROOT/lib/log.sh"; say hello 2>&1; ok finished 2>&1)"
  [ "$out" = "$(printf '==> hello\n ok finished')" ]
}
check "log helpers write plain text to stderr under NO_COLOR" t_log_no_color

t_log_stdout_clean() {
  [ -z "$(. "$ROOT/lib/log.sh"; say hello 2>/dev/null)" ]
}
check "log helpers keep stdout clean" t_log_stdout_clean

t_log_to_file() {
  /bin/bash -c '. "$1/lib/common.sh"; log_to_file; say logged' _ "$ROOT" 2>/dev/null
  sleep 0.2
  grep -rq 'logged' "$MACOS_STATE/logs"
}
check "log_to_file mirrors output into state/logs" t_log_to_file

t_err_trap_names_step() {
  local out
  out="$(/bin/bash -c '. "$1/lib/common.sh"; step "doing a thing"; false' _ "$ROOT" 2>&1)"
  printf '%s' "$out" | grep -q 'failed (exit 1) during: doing a thing'
}
check "ERR trap names the failing step" t_err_trap_names_step

t_err_reported_once() {
  local out
  out="$(/bin/bash -c '. "$1/lib/common.sh"; inner() { false; }; outer() { inner; }; outer' _ "$ROOT" 2>&1)"
  [ "$(printf '%s\n' "$out" | grep -c 'failed (exit')" -eq 1 ]
}
check "ERR trap reports a failure once, not per call level" t_err_reported_once

t_die_not_reported_as_failure() {
  local out
  out="$(/bin/bash -c '. "$1/lib/common.sh"; die "clear message"' _ "$ROOT" 2>&1)"
  printf '%s' "$out" | grep -q 'clear message' && ! printf '%s' "$out" | grep -q 'failed (exit'
}
check "die is not followed by a generic failure line" t_die_not_reported_as_failure

t_ok_marks_dry_run() {
  [ "$(MACOS_DRY_RUN=1 /bin/bash -c '. "$1/lib/log.sh"; ok installed x' _ "$ROOT" 2>&1)" = "  ~ installed x (dry run)" ]
}
check "ok lines are marked under --dry-run" t_ok_marks_dry_run

t_exit_hooks() {
  /bin/bash -c '. "$1/lib/common.sh"; on_exit "touch $2/a"; on_exit "touch $2/b"; exit 3' _ "$ROOT" "$SANDBOX" >/dev/null 2>&1
  [ $? -eq 3 ] && [ -f "$SANDBOX/a" ] && [ -f "$SANDBOX/b" ]
}
check "exit hooks all run and exit status is preserved" t_exit_hooks

LOCKRUN='. "$1/lib/common.sh"; . "$1/lib/lock.sh"; lock_acquire test; '

t_lock_contention() {
  /bin/bash -c "$LOCKRUN"'touch "$2/held"; sleep 5' _ "$ROOT" "$SANDBOX" >/dev/null 2>&1 &
  local holder=$! i=0 rc=0
  while [ ! -f "$SANDBOX/held" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  /bin/bash -c "$LOCKRUN" _ "$ROOT" >"$SANDBOX/o" 2>&1 || rc=$?
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  [ "$rc" -ne 0 ] && grep -q 'in progress' "$SANDBOX/o"
}
check "lock refuses a concurrent run" t_lock_contention

t_lock_released() {
  /bin/bash -c "$LOCKRUN"'true' _ "$ROOT" && [ ! -d "$MACOS_STATE/locks/test.lock" ]
}
check "lock is released on exit" t_lock_released

t_lock_stale() {
  mkdir -p "$MACOS_STATE/locks/test.lock"
  echo 999999 >"$MACOS_STATE/locks/test.lock/pid"
  /bin/bash -c "$LOCKRUN"'true' _ "$ROOT" 2>"$SANDBOX/o" && grep -q 'stale lock' "$SANDBOX/o"
}
check "stale lock is recovered" t_lock_stale

# ---------------------------------------------------------------------------
section "Prompts"

PROMPT_LIBS='. "$1/lib/common.sh"; . "$1/lib/run.sh"; . "$1/lib/prompt.sh"; '

t_choose_number() {
  printf '2\n' >"$SANDBOX/answers"
  [ "$(MACOS_TTY="$SANDBOX/answers" /bin/bash -c "$PROMPT_LIBS"'choose p "Profile?" work personal base; echo "$p"' _ "$ROOT" 2>/dev/null)" = personal ]
}
check "choose accepts a number" t_choose_number

t_choose_retry() {
  printf 'nope\nbase\n' >"$SANDBOX/answers"
  [ "$(MACOS_TTY="$SANDBOX/answers" /bin/bash -c "$PROMPT_LIBS"'choose p "Profile?" work personal base; echo "$p"' _ "$ROOT" 2>/dev/null)" = base ]
}
check "choose re-asks on invalid input and accepts option text" t_choose_retry

t_ask_default() {
  printf '\n' >"$SANDBOX/answers"
  [ "$(MACOS_TTY="$SANDBOX/answers" /bin/bash -c "$PROMPT_LIBS"'ask h "Name" studio; echo "$h"' _ "$ROOT" 2>/dev/null)" = studio ]
}
check "ask falls back to the default on an empty answer" t_ask_default

t_ask_yes_needs_default() {
  ! MACOS_YES=1 /bin/bash -c "$PROMPT_LIBS"'ask h "Name"' _ "$ROOT" 2>/dev/null
}
check "ask without a default fails under MACOS_YES" t_ask_yes_needs_default

t_no_tty() {
  local out
  out="$(MACOS_TTY=/nonexistent/tty /bin/bash -c "$PROMPT_LIBS"'ask h "Name"' _ "$ROOT" 2>&1)" && return 1
  printf '%s' "$out" | grep -q "no terminal to prompt on for 'Name'"
}
check "prompting without a terminal fails with guidance" t_no_tty

# ---------------------------------------------------------------------------
section "Brewfile merge"

BREW_LIBS='. "$1/lib/common.sh"; . "$1/lib/run.sh"; . "$1/lib/brew.sh"; '

t_merge_dedupe() {
  printf '# c\nbrew "git"\ncask "ghostty"   # term\n\n' >"$SANDBOX/B1"
  printf 'brew "git"\ncask "slack"\n' >"$SANDBOX/B2"
  /bin/bash -c "$BREW_LIBS"'brew_merge "$2/M" "$2/B1" "$2/B2"' _ "$ROOT" "$SANDBOX" || return 1
  [ "$(grep -c '^brew "git"$' "$SANDBOX/M")" -eq 1 ] &&
    grep -qx 'cask "ghostty"' "$SANDBOX/M" && grep -qx 'cask "slack"' "$SANDBOX/M" &&
    grep -q '^# Do not edit' "$SANDBOX/M"
}
check "merge concatenates, strips comments, de-duplicates" t_merge_dedupe

t_merge_conflict() {
  printf 'cask "x"\n' >"$SANDBOX/B1"
  printf 'cask "x", args: { adopt: true }\n' >"$SANDBOX/B2"
  ! /bin/bash -c "$BREW_LIBS"'brew_merge "$2/M2" "$2/B1" "$2/B2"' _ "$ROOT" "$SANDBOX" 2>"$SANDBOX/o" &&
    grep -q 'conflicting Brewfile entries' "$SANDBOX/o"
}
check "merge rejects one package declared with different options" t_merge_conflict

t_real_profiles_merge() {
  # The real private data repo, when present on this machine, must merge.
  local d="${MACOS_REAL_DOTFILES:-$REAL_HOME/.dotfiles}/macos/profiles"
  [ -d "$d" ] || { echo "no local dotfiles; skipped"; return 0; }
  /bin/bash -c "$BREW_LIBS"'brew_merge "$2/M3" "$3/base/Brewfile" "$3/work/Brewfile"' _ "$ROOT" "$SANDBOX" "$d"
}
check "real base+work Brewfiles merge cleanly (if present)" t_real_profiles_merge

# ---------------------------------------------------------------------------
section "Security"

SEC_LIBS='. "$1/lib/common.sh"; . "$1/lib/run.sh"; . "$1/lib/security.sh"; '

t_hostname_local() {
  [ "$(/bin/bash -c "$SEC_LIBS"'hostname_local "$2"' _ "$ROOT" "Angel$(printf '\342\200\231')s MacBook Pro")" = Angels-MacBook-Pro ] &&
    [ "$(/bin/bash -c "$SEC_LIBS"'hostname_local "  my  mac!! "' _ "$ROOT")" = my-mac ]
}
check "LocalHostName is sanitized" t_hostname_local

t_touchid_render() {
  /bin/bash -c "$SEC_LIBS"'touchid_render' _ "$ROOT" >"$SANDBOX/t1"
  mkdir -p "$HOMEBREW_PREFIX/lib/pam" && touch "$HOMEBREW_PREFIX/lib/pam/pam_reattach.so"
  /bin/bash -c "$SEC_LIBS"'touchid_render' _ "$ROOT" >"$SANDBOX/t2"
  rm -rf "${HOMEBREW_PREFIX:?}/lib"
  ! grep -q reattach "$SANDBOX/t1" && grep -q 'pam_tid.so' "$SANDBOX/t1" &&
    [ "$(grep -n reattach "$SANDBOX/t2" | cut -d: -f1)" -lt "$(grep -n pam_tid "$SANDBOX/t2" | cut -d: -f1)" ]
}
check "sudo_local adds pam_reattach before pam_tid when installed" t_touchid_render

t_touchid_idempotent() {
  /bin/bash -c "$SEC_LIBS"'touchid_render' _ "$ROOT" >"$PAM_SUDO_LOCAL"
  : >"$STUB_LOG"
  /bin/bash -c "$SEC_LIBS"'security_touchid' _ "$ROOT" 2>/dev/null
  local rc=$?
  rm -f "$PAM_SUDO_LOCAL"
  [ $rc -eq 0 ] && ! grep -q '^sudo' "$STUB_LOG"
}
check "Touch ID step is a no-op when sudo_local is already right" t_touchid_idempotent

t_firewall_idempotent() {
  : >"$STUB_LOG"
  STUB_SOCKETFILTERFW_OUT="Firewall is enabled. (State = 1) / stealth mode is on" \
    /bin/bash -c "$SEC_LIBS"'security_firewall' _ "$ROOT" 2>/dev/null &&
    ! grep -q -- '--set' "$STUB_LOG"
}
check "firewall step changes nothing when already on" t_firewall_idempotent

t_firewall_disabled_is_not_enabled() {
  : >"$STUB_LOG"
  STUB_SOCKETFILTERFW_OUT="Firewall is disabled. (State = 0)" \
    /bin/bash -c "$SEC_LIBS"'security_firewall' _ "$ROOT" 2>/dev/null &&
    grep -q -- '--setglobalstate on' "$STUB_LOG"
}
check "firewall step treats 'disabled' as off" t_firewall_disabled_is_not_enabled

t_analytics_not_fooled_by_env() {
  : >"$STUB_LOG"
  HOMEBREW_NO_ANALYTICS=1 /bin/bash -c "$SEC_LIBS"'security_analytics' _ "$ROOT" 2>/dev/null &&
    grep -q '^brew analytics off' "$STUB_LOG"
}
check "analytics check ignores our own HOMEBREW_NO_ANALYTICS" t_analytics_not_fooled_by_env

t_analytics_idempotent() {
  : >"$STUB_LOG"
  STUB_BREW_ANALYTICS_OFF=1 /bin/bash -c "$SEC_LIBS"'security_analytics' _ "$ROOT" 2>/dev/null &&
    ! grep -q '^brew analytics off' "$STUB_LOG"
}
check "analytics step changes nothing when already off" t_analytics_idempotent

t_sudo_keepalive_quiet_exit() {
  # Regression: the killed keepalive loop printed "Terminated: 15" when the
  # lock's exit hook ran after it.
  local i
  for i in 1 2 3; do
    /bin/bash -c '. "$1/lib/common.sh"; . "$1/lib/run.sh"; . "$1/lib/lock.sh"; . "$1/lib/sudo.sh"; lock_acquire kq; sudo_keepalive; sleep 0.2; exit 0' _ "$ROOT" >"$SANDBOX/o" 2>&1 || return 1
    ! grep -q Terminated "$SANDBOX/o" || { cat "$SANDBOX/o"; return 1; }
  done
}
check "sudo keepalive stops silently at exit" t_sudo_keepalive_quiet_exit

t_sudo_keepalive_stops() {
  /bin/bash -c '. "$1/lib/common.sh"; . "$1/lib/run.sh"; . "$1/lib/sudo.sh"; sudo_keepalive; echo "$_MACOS_SUDO_PID" >"$2/kpid"' _ "$ROOT" "$SANDBOX" 2>/dev/null
  sleep 0.3
  ! kill -0 "$(cat "$SANDBOX/kpid")" 2>/dev/null
}
check "sudo keepalive loop is gone after exit" t_sudo_keepalive_stops

# ---------------------------------------------------------------------------
section "Pending steps"

PEND_LIBS='. "$1/lib/common.sh"; . "$1/lib/run.sh"; . "$1/lib/pending.sh"; '

t_pending() {
  rm -f "$MACOS_STATE/pending"
  /bin/bash -c "$PEND_LIBS"'pending_add a "Do A"; pending_add a "Do A"; pending_add b "Do B"; pending_done a; pending_list' _ "$ROOT" >"$SANDBOX/o" &&
    [ "$(cat "$SANDBOX/o")" = "Do B" ]
}
check "pending steps are de-duplicated and can be marked done" t_pending

# ---------------------------------------------------------------------------
section "Bootstrap"

make_dotfiles_fixture() {
  rm -rf "$MACOS_DOTFILES"
  mkdir -p "$MACOS_DOTFILES/.git" "$MACOS_DOTFILES/.githooks" "$MACOS_DOTFILES/macos/profiles/base" "$MACOS_DOTFILES/macos/profiles/work"
  printf 'brew "git"\ncask "tailscale-app"\n' >"$MACOS_DOTFILES/macos/profiles/base/Brewfile"
  printf 'cask "slack"\n' >"$MACOS_DOTFILES/macos/profiles/work/Brewfile"
}

bootstrap_env() {
  rm -rf "$MACOS_STATE"
  make_dotfiles_fixture
  : >"$STUB_LOG"
}

t_bootstrap_requires_profile_with_yes() {
  bootstrap_env
  "$M" bootstrap --yes >"$SANDBOX/o" 2>&1 && return 1
  grep -q -- '--profile is required' "$SANDBOX/o"
}
check "bootstrap --yes without --profile refuses" t_bootstrap_requires_profile_with_yes

t_bootstrap_rejects_unknown_profile() {
  bootstrap_env
  "$M" bootstrap --yes --profile gaming --hostname x >"$SANDBOX/o" 2>&1 && return 1
  grep -q "unknown profile 'gaming'" "$SANDBOX/o"
}
check "bootstrap rejects an unknown profile" t_bootstrap_rejects_unknown_profile

t_bootstrap_full() {
  bootstrap_env
  STUB_TAILSCALE_CLI_RC=1 STUB_BREW_BUNDLE_CHECK_RC=1 STUB_GH_OUT="  - Token scopes: 'admin:public_key', 'admin:ssh_signing_key', 'repo'" \
    "$M" bootstrap --yes --profile work --hostname "Studio Mac" >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  local L="$STUB_LOG" E="$MACOS_STATE/machine.env" B="$MACOS_STATE/Brewfile"
  grep -qx 'MACOS_PROFILE="work"' "$E" && grep -qx 'MACOS_HOSTNAME="Studio Mac"' "$E" || { echo "machine.env"; cat "$E"; return 1; }
  grep -q "^sudo tee $PAM_SUDO_LOCAL" "$L" || { echo "touchid"; return 1; }
  grep -q -- '--setglobalstate on' "$L" && grep -q -- '--setstealthmode on' "$L" || { echo "firewall"; return 1; }
  grep -q '^brew analytics off' "$L" || { echo "analytics"; return 1; }
  grep -q '^sudo scutil --set ComputerName Studio Mac' "$L" && grep -q '^sudo scutil --set LocalHostName Studio-Mac' "$L" || { echo "hostname"; return 1; }
  grep -q '^gh config set git_protocol https' "$L" && ! grep -q '^gh auth refresh' "$L" || { echo "gh"; return 1; }
  grep -q "^git -c credential.helper= -c credential.helper=!gh auth git-credential -C $MACOS_DOTFILES pull --ff-only" "$L" || { echo "pull"; return 1; }
  grep -q "^git -C $MACOS_DOTFILES config core.hooksPath .githooks" "$L" || { echo "hooks"; return 1; }
  grep -qx 'brew "git"' "$B" && grep -qx 'cask "slack"' "$B" || { echo "merge"; return 1; }
  grep -q "^brew bundle install --file=$B --no-upgrade" "$L" || { echo "bundle"; return 1; }
  grep -q '^tailscale|' "$MACOS_STATE/pending" || { echo "pending"; return 1; }
  ls "$MACOS_STATE"/logs/*macos-bootstrap.log >/dev/null || { echo "log"; return 1; }
}
check "bootstrap --yes runs the security, GitHub, clone and app phases with the right commands" t_bootstrap_full

t_bootstrap_missing_scope() {
  bootstrap_env
  STUB_GH_OUT="  - Token scopes: 'repo'" "$M" bootstrap --yes --profile work --hostname x >"$SANDBOX/o" 2>&1 && return 1
  grep -q 'lacks scopes admin:public_key,admin:ssh_signing_key' "$SANDBOX/o"
}
check "bootstrap --yes stops with guidance when gh lacks scopes" t_bootstrap_missing_scope

t_bootstrap_dry_run() {
  bootstrap_env
  STUB_GH_OUT="  - Token scopes: 'admin:public_key', 'admin:ssh_signing_key'" \
    "$M" bootstrap --yes --dry-run --profile work --hostname x >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  [ ! -f "$MACOS_STATE/machine.env" ] && [ ! -f "$MACOS_STATE/Brewfile" ] && [ ! -f "$MACOS_STATE/pending" ] || { echo "state written"; return 1; }
  ! grep -qE '^(sudo |brew bundle install|brew analytics off|gh config set|git .*pull)' "$STUB_LOG" || { echo "mutated:"; cat "$STUB_LOG"; return 1; }
  grep -q 'would run: sudo scutil --set' "$SANDBOX/o"
}
check "bootstrap --dry-run changes nothing and shows the plan" t_bootstrap_dry_run

t_bootstrap_sudo_preflight() {
  # No cached sudo and no terminal: stop before any step runs.
  bootstrap_env
  STUB_SUDO_RC=1 "$M" bootstrap --yes --profile work --hostname x </dev/null >"$SANDBOX/o" 2>&1 && return 1
  grep -q 'no terminal to type the password in' "$SANDBOX/o" && ! grep -q '==> Profile' "$SANDBOX/o" &&
    [ ! -f "$MACOS_STATE/machine.env" ]
}
if (exec </dev/tty) 2>/dev/null; then
  printf '  skip sudo preflight test (this shell has a terminal)\n'
else
  check "bootstrap stops before any change when sudo cannot prompt" t_bootstrap_sudo_preflight
fi

t_bootstrap_interactive() {
  bootstrap_env
  printf '2\n\n' >"$SANDBOX/answers"
  STUB_SCUTIL_OUT="Current Name" STUB_GH_OUT="  - Token scopes: 'admin:public_key', 'admin:ssh_signing_key'" \
    MACOS_TTY="$SANDBOX/answers" "$M" bootstrap --dry-run >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q 'profile: personal, computer name: Current Name' "$SANDBOX/o"
}
check "bootstrap prompts for profile and hostname on the terminal" t_bootstrap_interactive

# ---------------------------------------------------------------------------
section "apply"

phase3_env() {
  rm -rf "$MACOS_STATE" "$SANDBOX/Applications"
  make_dotfiles_fixture
  mkdir -p "$MACOS_STATE" "$SANDBOX/Applications"
  printf 'MACOS_PROFILE="work"\n' >"$MACOS_STATE/machine.env"
  : >"$STUB_LOG"
}
W="$MACOS_DOTFILES/macos/profiles/work/Brewfile"
BASEF="$MACOS_DOTFILES/macos/profiles/base/Brewfile"

t_apply_requires_profile() {
  phase3_env; rm -f "$MACOS_STATE/machine.env"
  "$M" apply >"$SANDBOX/o" 2>&1 && return 1
  grep -q 'no profile set for this Mac' "$SANDBOX/o"
}
check "apply refuses before bootstrap" t_apply_requires_profile

t_apply_noop() {
  phase3_env
  "$M" apply >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q 'all declared apps are installed' "$SANDBOX/o" && ! grep -q 'bundle install' "$STUB_LOG" &&
    grep -qx 'cask "slack"' "$MACOS_STATE/Brewfile"
}
check "apply changes nothing when everything is installed" t_apply_noop

t_apply_installs() {
  phase3_env
  STUB_BREW_BUNDLE_CHECK_RC=1 "$M" apply >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q "^brew bundle install --file=$MACOS_STATE/Brewfile --no-upgrade" "$STUB_LOG"
}
check "apply installs missing entries without upgrading" t_apply_installs

t_apply_dry_run() {
  phase3_env
  STUB_BREW_BUNDLE_CHECK_RC=1 STUB_BREW_BUNDLE_CHECK_OUT="→ Cask slack needs to be installed." \
    "$M" apply --dry-run >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q '    cask slack' "$SANDBOX/o" && ! grep -q 'bundle install' "$STUB_LOG" && [ ! -f "$MACOS_STATE/Brewfile" ]
}
check "apply --dry-run lists what it would install and writes nothing" t_apply_dry_run

t_apply_warns_adoptable() {
  phase3_env
  mkdir -p "$SANDBOX/Applications/Slack.app"
  STUB_BREW_BUNDLE_CHECK_RC=1 STUB_BREW_BUNDLE_CHECK_OUT="→ Cask slack needs to be installed." \
    STUB_BREW_INFO___CASK_OUT='{"casks":[{"artifacts":[{"app":["Slack.app"]},{"zap":[]}]}]}' \
    MACOS_APPLICATIONS_DIRS="$SANDBOX/Applications" "$M" apply >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q 'installed by hand.*slack' "$SANDBOX/o" && grep -q "macos apps adopt" "$SANDBOX/o"
}
check "apply points hand-installed apps at 'apps adopt'" t_apply_warns_adoptable

t_prune_nothing() {
  phase3_env
  STUB_BREW_BUNDLE_CLEANUP_RC=0 "$M" apply --prune --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q 'nothing to prune' "$SANDBOX/o" && ! grep -q -- '--force' "$STUB_LOG"
}
check "prune does nothing when nothing is undeclared" t_prune_nothing

PRUNE_OUT="$(printf 'Would uninstall formulae:\njq\nRun `brew bundle cleanup --force` to make these changes.')"

t_prune_confirmed() {
  phase3_env
  STUB_LOG_ENV="HOMEBREW_BUNDLE_CLEANUP_NO_MAS HOMEBREW_BUNDLE_CLEANUP_NO_NPM" \
    STUB_BREW_BUNDLE_CLEANUP_RC=1 STUB_BREW_BUNDLE_CLEANUP___FORCE_RC=0 STUB_BREW_BUNDLE_CLEANUP_OUT="$PRUNE_OUT" \
    "$M" apply --prune --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q '    jq' "$SANDBOX/o" &&
    grep -q "^brew bundle cleanup --force --file=$MACOS_STATE/Brewfile \[HOMEBREW_BUNDLE_CLEANUP_NO_MAS=1\] \[HOMEBREW_BUNDLE_CLEANUP_NO_NPM=1\]" "$STUB_LOG" &&
    grep -q "^brew bundle cleanup --file=.*NO_MAS=1" "$STUB_LOG"
}
check "prune shows the list, keeps App Store/npm cleaners off, then forces" t_prune_confirmed

t_prune_declined() {
  phase3_env
  printf 'n\n' >"$SANDBOX/answers"
  MACOS_TTY="$SANDBOX/answers" STUB_BREW_BUNDLE_CLEANUP_RC=1 STUB_BREW_BUNDLE_CLEANUP_OUT="$PRUNE_OUT" \
    "$M" apply --prune >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q 'prune cancelled' "$SANDBOX/o" && ! grep -q -- '--force' "$STUB_LOG"
}
check "prune removes nothing when not confirmed" t_prune_declined

t_prune_dry_run() {
  phase3_env
  STUB_BREW_BUNDLE_CLEANUP_RC=1 STUB_BREW_BUNDLE_CLEANUP_OUT="$PRUNE_OUT" \
    "$M" apply --prune --dry-run --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q '    jq' "$SANDBOX/o" && ! grep -q -- '--force' "$STUB_LOG"
}
check "prune --dry-run only lists" t_prune_dry_run

t_prune_error() {
  phase3_env
  STUB_BREW_BUNDLE_CLEANUP_RC=2 STUB_BREW_BUNDLE_CLEANUP_OUT="Error: boom" \
    "$M" apply --prune --yes >"$SANDBOX/o" 2>&1 && return 1
  grep -q 'cleanup failed (exit 2)' "$SANDBOX/o" && ! grep -q -- '--force' "$STUB_LOG"
}
check "prune stops on a cleanup error instead of guessing" t_prune_error

# ---------------------------------------------------------------------------
section "upgrade"

t_upgrade() {
  phase3_env
  "$M" upgrade >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q '^brew update --quiet' "$STUB_LOG" &&
    grep -q "^brew bundle install --file=$MACOS_STATE/Brewfile --upgrade" "$STUB_LOG" &&
    grep -q '^mise upgrade' "$STUB_LOG" && grep -q '^softwareupdate --list' "$STUB_LOG" &&
    ! grep -q '^softwareupdate --install' "$STUB_LOG"
}
check "upgrade upgrades declared packages and runtimes, only lists macOS updates" t_upgrade

t_upgrade_dry_run() {
  phase3_env
  "$M" upgrade --dry-run >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q '^brew outdated' "$STUB_LOG" && ! grep -qE '^brew (update|bundle install)|^mise upgrade' "$STUB_LOG"
}
check "upgrade --dry-run only reports" t_upgrade_dry_run

# ---------------------------------------------------------------------------
section "apps"

t_add_cask() {
  phase3_env
  STUB_BREW_LIST_RC=1 "$M" apps add spotify --cask >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q "^brew bundle add --file=$W --cask spotify" "$STUB_LOG" && grep -q '^brew install --cask spotify' "$STUB_LOG"
}
check "apps add declares in this Mac's profile, then installs" t_add_cask

t_add_already() {
  phase3_env
  "$M" apps add slack --cask >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q 'already declared in work' "$SANDBOX/o" && ! grep -q 'bundle add' "$STUB_LOG"
}
check "apps add does not duplicate an entry (brew bundle add would)" t_add_already

t_add_in_base() {
  phase3_env
  "$M" apps add git --formula --profile work >"$SANDBOX/o" 2>&1 && return 1
  grep -q 'already declared in base' "$SANDBOX/o"
}
check "apps add refuses to repeat a base entry in a profile" t_add_in_base

t_add_detects_type() {
  phase3_env
  STUB_BREW_INFO___CASK_RC=1 "$M" apps add htop --no-install >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q "^brew bundle add --file=$W --formula htop" "$STUB_LOG" && ! grep -q '^brew install' "$STUB_LOG"
}
check "apps add detects a formula and honours --no-install" t_add_detects_type

t_add_ambiguous() {
  phase3_env
  "$M" apps add docker >"$SANDBOX/o" 2>&1 && return 1
  grep -q 'both a formula and a cask' "$SANDBOX/o"
}
check "apps add asks for --formula/--cask when the name is ambiguous" t_add_ambiguous

t_add_other_profile() {
  phase3_env; mkdir -p "$MACOS_DOTFILES/macos/profiles/personal"
  "$M" apps add spotify --cask --profile personal >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q "^brew bundle add --file=$MACOS_DOTFILES/macos/profiles/personal/Brewfile --cask spotify" "$STUB_LOG" &&
    grep -q "not this Mac's profile" "$SANDBOX/o" && ! grep -q '^brew install' "$STUB_LOG"
}
check "apps add to another profile declares without installing here" t_add_other_profile

t_remove() {
  phase3_env
  "$M" apps remove slack --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q "^brew bundle remove --file=$W --cask slack" "$STUB_LOG" && grep -q '^brew uninstall --cask slack' "$STUB_LOG"
}
check "apps remove undeclares and uninstalls" t_remove

t_remove_undeclared() {
  phase3_env
  "$M" apps remove nothere --yes >"$SANDBOX/o" 2>&1 && return 1
  grep -q 'not declared in any profile' "$SANDBOX/o"
}
check "apps remove refuses an undeclared name" t_remove_undeclared

t_remove_still_in_base() {
  phase3_env
  printf 'cask "slack"\n' >>"$BASEF"
  "$M" apps remove slack --profile work --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q "bundle remove --file=$W" "$STUB_LOG" && ! grep -q "bundle remove --file=$BASEF" "$STUB_LOG" &&
    grep -q 'still declared in base' "$SANDBOX/o" && ! grep -q '^brew uninstall' "$STUB_LOG"
}
check "apps remove keeps it installed while another active profile wants it" t_remove_still_in_base

t_remove_keep() {
  phase3_env
  "$M" apps remove slack --keep-installed --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  ! grep -q '^brew uninstall' "$STUB_LOG"
}
check "apps remove --keep-installed only undeclares" t_remove_keep

t_remove_tap_and_mas() {
  phase3_env
  printf 'tap "someone/tools"\nmas "Xcode", id: 497799835\n' >>"$W"
  STUB_BREW_TAP_OUT="someone/tools" "$M" apps remove someone/tools --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  "$M" apps remove Xcode --yes >>"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q "^brew bundle remove --file=$W --tap someone/tools" "$STUB_LOG" && grep -q '^brew untap someone/tools' "$STUB_LOG" &&
    grep -q "^brew bundle remove --file=$W --mas Xcode" "$STUB_LOG" && ! grep -q 'uninstall .*Xcode' "$STUB_LOG" &&
    grep -q 'from Finder or Launchpad' "$SANDBOX/o" || { cat "$STUB_LOG"; return 1; }
}
check "apps remove handles taps (untap) and App Store entries (undeclare only)" t_remove_tap_and_mas

DUMP_OUT="$(printf 'brew "git"\nbrew "htop"\ncask "slack"\ntap "someone/tools"')"

t_adopt_strays() {
  phase3_env
  STUB_BREW_BUNDLE_DUMP_OUT="$DUMP_OUT" "$M" apps adopt --yes --profile work >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q "^brew bundle add --file=$W --formula htop" "$STUB_LOG" &&
    grep -q "^brew bundle add --file=$W --tap someone/tools" "$STUB_LOG" &&
    ! grep -qE 'bundle add .*(git|slack)$' "$STUB_LOG"
}
check "apps adopt declares only undeclared installs" t_adopt_strays

t_adopt_needs_profile_with_yes() {
  phase3_env
  STUB_BREW_BUNDLE_DUMP_OUT="$DUMP_OUT" "$M" apps adopt --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q '    brew htop' "$SANDBOX/o" && grep -q 'pass --profile' "$SANDBOX/o" && ! grep -q 'bundle add' "$STUB_LOG"
}
check "apps adopt --yes without --profile only lists" t_adopt_needs_profile_with_yes

t_adopt_interactive() {
  phase3_env
  printf '1\n3\n' >"$SANDBOX/answers"
  STUB_BREW_BUNDLE_DUMP_OUT="$DUMP_OUT" MACOS_TTY="$SANDBOX/answers" "$M" apps adopt >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q "^brew bundle add --file=$BASEF --formula htop" "$STUB_LOG" && grep -q 'left someone/tools undeclared' "$SANDBOX/o"
}
check "apps adopt asks per package (base / profile / skip)" t_adopt_interactive

t_adopt_hand_installed() {
  phase3_env
  mkdir -p "$SANDBOX/Applications/Slack.app"
  STUB_BREW_BUNDLE_CHECK_RC=1 STUB_BREW_BUNDLE_CHECK_OUT="→ Cask slack needs to be installed." \
    STUB_BREW_INFO___CASK_OUT='{"casks":[{"artifacts":[{"app":["Slack.app"]}]}]}' \
    MACOS_APPLICATIONS_DIRS="$SANDBOX/Applications" "$M" apps adopt --yes --profile work >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q '^brew install --cask --adopt slack' "$STUB_LOG"
}
check "apps adopt hands a hand-installed app to Homebrew" t_adopt_hand_installed

# ---------------------------------------------------------------------------
section "dotfiles"

# Real GNU Stow: source and target are both inside the sandbox.
command -v stow >/dev/null 2>&1 || { echo "FATAL: GNU Stow is required for the dotfiles tests" >&2; exit 1; }

dotfiles_env() {
  phase3_env
  rm -rf "$HOME" && mkdir -p "$HOME"
  local d="$MACOS_DOTFILES"
  mkdir -p "$d/zsh/.config/zsh" "$d/git/.config/git" "$d/extra" "$d/personalonly"
  printf 'zshrc\n' >"$d/zsh/.zshrc"
  printf 'a\n' >"$d/zsh/.config/zsh/a.zsh"
  printf 'readme\n' >"$d/zsh/README.md"
  printf 'junk\n' >"$d/zsh/.DS_Store"
  printf '[user]\n' >"$d/git/.config/git/config"
  printf 'extra\n' >"$d/extra/.extrarc"
  printf 'p\n' >"$d/personalonly/.personalrc"
  printf '# base\nzsh\ngit   # comment\n\n' >"$d/macos/profiles/base/stow.list"
  printf 'extra\ngit\n' >"$d/macos/profiles/work/stow.list"
  mkdir -p "$d/macos/profiles/personal"
  printf 'personalonly\n' >"$d/macos/profiles/personal/stow.list"
}

is_link_into_repo() { [ -L "$HOME/$1" ] && [ "$(readlink -f "$HOME/$1")" = "$(readlink -f "$MACOS_DOTFILES/$2/$1")" ]; }

t_link_fresh() {
  dotfiles_env
  "$M" dotfiles link >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  is_link_into_repo .zshrc zsh && is_link_into_repo .config/zsh/a.zsh zsh &&
    is_link_into_repo .config/git/config git && is_link_into_repo .extrarc extra &&
    [ -d "$HOME/.config" ] && [ ! -L "$HOME/.config" ] && [ ! -L "$HOME/.config/zsh" ] &&
    [ ! -e "$HOME/README.md" ] && [ ! -e "$HOME/.DS_Store" ] && [ ! -e "$HOME/.personalrc" ]
}
check "link symlinks base + profile packages file by file (no folding)" t_link_fresh

t_link_backs_up() {
  dotfiles_env
  printf 'mine\n' >"$HOME/.zshrc"
  ln -s /somewhere/else "$HOME/.extrarc"
  "$M" dotfiles link >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  is_link_into_repo .zshrc zsh && is_link_into_repo .extrarc extra &&
    [ "$(cat "$MACOS_STATE"/backup/*/.zshrc)" = mine ] &&
    [ "$(readlink "$MACOS_STATE"/backup/*/.extrarc)" = /somewhere/else ] &&
    grep -q 'Backed up 2 file' "$SANDBOX/o"
}
check "link moves real files and foreign symlinks to a backup first" t_link_backs_up

t_link_idempotent() {
  dotfiles_env
  "$M" dotfiles link >/dev/null 2>&1 && "$M" dotfiles link >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  [ ! -d "$MACOS_STATE/backup" ] && is_link_into_repo .zshrc zsh
}
check "link twice changes nothing and backs nothing up" t_link_idempotent

t_apply_second_run_quiet() {
  dotfiles_env
  "$M" apply >/dev/null 2>&1; : >"$STUB_LOG"
  "$M" apply >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  # Only the final "apply finished" is an ok line: nothing else changed.
  [ "$(grep -c '^ ok ' "$SANDBOX/o")" -eq 1 ] && grep -q '^ ok apply finished' "$SANDBOX/o" &&
    ! grep -qE '^(stow|mise install)' "$STUB_LOG" && grep -q 'dotfiles already linked' "$SANDBOX/o" || { cat "$SANDBOX/o"; return 1; }
}
check "a second apply changes nothing and says so (only \"apply finished\")" t_apply_second_run_quiet

t_link_dry_run() {
  dotfiles_env
  printf 'mine\n' >"$HOME/.zshrc"
  "$M" dotfiles link --dry-run >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  [ "$(cat "$HOME/.zshrc")" = mine ] && [ ! -L "$HOME/.zshrc" ] && [ ! -e "$HOME/.config/git/config" ] &&
    grep -q 'would run: mv' "$SANDBOX/o" && grep -q 'would run: stow' "$SANDBOX/o"
}
check "link --dry-run touches nothing" t_link_dry_run

t_status() {
  dotfiles_env
  "$M" dotfiles link >/dev/null 2>&1
  "$M" dotfiles status >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  rm "$HOME/.extrarc"
  printf 'x\n' >"$HOME/.config/zsh/stray.zsh"
  rm "$HOME/.config/zsh/a.zsh" && printf 'edited\n' >"$HOME/.config/zsh/a.zsh"
  "$M" dotfiles status >"$SANDBOX/o2" 2>&1 && return 1
  grep -q 'missing   ~/.extrarc' "$SANDBOX/o2" && grep -q 'conflict  ~/.config/zsh/a.zsh' "$SANDBOX/o2" &&
    grep -q 'linked    ~/.zshrc' "$SANDBOX/o2"
}
check "status reports linked / missing / conflict and exits 1 on drift" t_status

t_unlink() {
  dotfiles_env
  "$M" dotfiles link >/dev/null 2>&1
  "$M" dotfiles unlink >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  [ ! -e "$HOME/.zshrc" ] && [ ! -e "$HOME/.config/git/config" ] && [ -f "$MACOS_DOTFILES/zsh/.zshrc" ]
}
check "unlink removes the links and leaves the repo alone" t_unlink

t_link_folded_parent() {
  dotfiles_env
  # An older folded stow: ~/.config/zsh is itself a link into the repo.
  mkdir -p "$HOME/.config" && ln -s "$MACOS_DOTFILES/zsh/.config/zsh" "$HOME/.config/zsh"
  "$M" dotfiles link >"$SANDBOX/o" 2>&1
  [ -f "$MACOS_DOTFILES/zsh/.config/zsh/a.zsh" ] && [ ! -d "$MACOS_STATE/backup" ] || { cat "$SANDBOX/o"; ls -R "$MACOS_STATE" 2>/dev/null; return 1; }
}
check "link never moves the repo's own files when a parent dir is a folded link" t_link_folded_parent

t_link_missing_package() {
  dotfiles_env
  printf 'nosuchpkg\n' >>"$MACOS_DOTFILES/macos/profiles/work/stow.list"
  "$M" dotfiles link >"$SANDBOX/o" 2>&1 && return 1
  grep -q "names 'nosuchpkg'" "$SANDBOX/o" && [ ! -e "$HOME/.zshrc" ]
}
check "link refuses a stow.list entry with no package, before linking anything" t_link_missing_package

t_apply_links_and_installs_runtimes() {
  dotfiles_env
  STUB_MISE_LS_OUT="node lts (missing)" STUB_GH_OUT="gho_SECRETTOKEN123" "$M" apply >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  is_link_into_repo .zshrc zsh && grep -q '^mise install --yes$' "$STUB_LOG" &&
    ! grep -rq SECRETTOKEN "$SANDBOX/o" "$STUB_LOG" "$MACOS_STATE/logs"
}
check "apply links dotfiles and installs mise runtimes without leaking the token" t_apply_links_and_installs_runtimes

# ---------------------------------------------------------------------------
section "defaults"

defaults_env() {
  phase3_env
  rm -f "$STUB_DEFAULTS_DB" && : >"$STUB_DEFAULTS_DB"
  rm -rf "$HOME" "$MANAGED_PREFS_DIR" && mkdir -p "$HOME"
  cat >"$MACOS_DOTFILES/macos/profiles/base/defaults.conf" <<'CONF'
# comment
-g                                | KeyRepeat                   | int    | 2
com.apple.dock                    | autohide                    | bool   | true
com.apple.dock                    | autohide-delay              | float  | 0
com.apple.screencapture           | location                    | string | ~/Screenshots
@currentHost:-g                   | com.apple.mouse.tapBehavior | int    | 1
com.apple.AppleMultitouchTrackpad | Clicking                    | int    | 1
CONF
  printf 'com.apple.dock | autohide | bool | no\n' >"$MACOS_DOTFILES/macos/profiles/work/defaults.conf"
}

t_defaults_apply() {
  defaults_env
  "$M" defaults apply >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  local L="$STUB_LOG"
  grep -q '^defaults write -g KeyRepeat -int 2$' "$L" &&
    grep -q '^defaults write com.apple.dock autohide -bool false$' "$L" &&
    ! grep -q 'autohide -bool true' "$L" &&
    grep -q '^defaults write com.apple.dock autohide-delay -float 0$' "$L" &&
    grep -q "^defaults write com.apple.screencapture location -string $HOME/Screenshots\$" "$L" && [ -d "$HOME/Screenshots" ] &&
    grep -q '^defaults -currentHost write -g com.apple.mouse.tapBehavior -int 1$' "$L" &&
    grep -q '^killall Dock' "$L" && grep -q '^killall SystemUIServer' "$L" && grep -q '^activateSettings -u' "$L" ||
    { cat "$L"; return 1; }
}
check "defaults apply writes typed values; profile overrides base; restarts what changed" t_defaults_apply

t_defaults_idempotent() {
  defaults_env
  "$M" defaults apply >/dev/null 2>&1; : >"$STUB_LOG"
  "$M" defaults apply >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  ! grep -q 'defaults.* write' "$STUB_LOG" && ! grep -q '^killall' "$STUB_LOG" && grep -q 'already set' "$SANDBOX/o"
}
check "defaults apply twice writes nothing the second time" t_defaults_idempotent

t_defaults_check() {
  defaults_env
  "$M" defaults check >"$SANDBOX/o" 2>&1 && return 1
  grep -q 'drift  -g KeyRepeat: (unset) → 2' "$SANDBOX/o" && ! grep -q 'defaults.* write' "$STUB_LOG" || { cat "$SANDBOX/o"; return 1; }
  "$M" defaults apply >/dev/null 2>&1
  "$M" defaults check >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q 'no drift' "$SANDBOX/o"
}
check "defaults check reports drift without writing, then passes after apply" t_defaults_check

t_defaults_type_drift() {
  defaults_env
  "$M" defaults apply >/dev/null 2>&1
  # Same value, wrong type: stored as a boolean, declared as an int.
  defaults write com.apple.AppleMultitouchTrackpad Clicking -bool true
  "$M" defaults check >"$SANDBOX/o" 2>&1 && return 1
  grep -q 'Clicking: 1 (boolean) → 1' "$SANDBOX/o" || { cat "$SANDBOX/o"; return 1; }
  : >"$STUB_LOG"; "$M" defaults apply >/dev/null 2>&1
  grep -q '^defaults write com.apple.AppleMultitouchTrackpad Clicking -int 1$' "$STUB_LOG"
}
check "a value stored with the wrong type counts as drift and is rewritten" t_defaults_type_drift

t_defaults_float_normalized() {
  defaults_env
  "$M" defaults apply >/dev/null 2>&1
  printf 'global|com.apple.dock|autohide-delay|float|0.000\n' >>"$STUB_DEFAULTS_DB"
  "$M" defaults check >"$SANDBOX/o" 2>&1; ! grep -q autohide-delay "$SANDBOX/o"
}
check "float values compare numerically (0 == 0.000)" t_defaults_float_normalized

t_defaults_not_taken() {
  defaults_env
  STUB_DEFAULTS_IGNORE_WRITES=1 "$M" defaults apply >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q 'KeyRepeat did not take' "$SANDBOX/o"
}
check "a write that does not read back is reported" t_defaults_not_taken

t_defaults_dry_run() {
  defaults_env
  "$M" defaults apply --dry-run >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  ! grep -q 'defaults.* write' "$STUB_LOG" && [ ! -d "$HOME/Screenshots" ] && ! grep -q '^killall' "$STUB_LOG" &&
    grep -q 'would run: defaults write -g KeyRepeat -int 2' "$SANDBOX/o"
}
check "defaults apply --dry-run writes nothing" t_defaults_dry_run

t_defaults_invalid_line() {
  defaults_env
  printf 'com.apple.dock | orphan\n' >>"$MACOS_DOTFILES/macos/profiles/base/defaults.conf"
  "$M" defaults apply >"$SANDBOX/o" 2>&1 && return 1
  grep -q 'expected domain | key | type | value' "$SANDBOX/o"
}
check "a malformed defaults.conf line stops the run" t_defaults_invalid_line

# ---------------------------------------------------------------------------
section "system settings"

system_env() {
  defaults_env
  rm -f "$MACOS_DOTFILES/macos/profiles/"*/defaults.conf
  rm -rf "$SANDBOX/Applications" && mkdir -p "$SANDBOX/Applications/A.app" "$SANDBOX/Applications/My App.app"
  printf '%s\n' "$SANDBOX/Applications/A.app" "$SANDBOX/Applications/My App.app" "$SANDBOX/Applications/Missing.app" \
    >"$MACOS_DOTFILES/macos/profiles/base/dock.conf"
  printf 'capslock = none\nbrowser = none\n' >"$MACOS_DOTFILES/macos/profiles/base/system.conf"
}
TAB="$(printf '\t')"

t_dock_apply() {
  system_env
  STUB_DOCKUTIL___LIST_OUT="Safari${TAB}file:///Applications/Safari.app/${TAB}persistentApps${TAB}/p${TAB}com.apple.Safari
Downloads${TAB}file:///Users/x/Downloads/${TAB}persistentOthers${TAB}/p${TAB}" \
    "$M" defaults apply >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q '^dockutil --remove com.apple.Safari --no-restart' "$STUB_LOG" && ! grep -q 'remove Downloads' "$STUB_LOG" &&
    grep -q "^dockutil --add $SANDBOX/Applications/A.app --no-restart" "$STUB_LOG" &&
    grep -q "^dockutil --add $SANDBOX/Applications/My App.app --no-restart" "$STUB_LOG" &&
    ! grep -q 'Missing.app --no-restart' "$STUB_LOG" && grep -q 'Missing.app is not installed' "$SANDBOX/o" &&
    grep -q '^killall Dock' "$STUB_LOG" || { cat "$STUB_LOG"; return 1; }
}
check "Dock: replaces only the app section, in dock.conf order, skipping missing apps" t_dock_apply

t_dock_idempotent() {
  system_env
  STUB_DOCKUTIL___LIST_OUT="A${TAB}file://$SANDBOX/Applications/A.app/${TAB}persistentApps${TAB}/p${TAB}com.a
My App${TAB}file://$SANDBOX/Applications/My%20App.app/${TAB}persistentApps${TAB}/p${TAB}com.myapp" \
    "$M" defaults apply >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  ! grep -qE '^dockutil --(add|remove)' "$STUB_LOG" && grep -q 'Dock already matches' "$SANDBOX/o"
}
check "Dock: no changes when it already matches (URL-decoded paths)" t_dock_idempotent

t_capslock() {
  system_env
  printf 'capslock = escape\n' >"$MACOS_DOTFILES/macos/profiles/work/system.conf"
  "$M" defaults apply >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  local agent="$HOME/Library/LaunchAgents/com.ar4mirez.macos.capslock.plist"
  plutil -lint "$agent" >/dev/null && grep -q '0x700000029' "$agent" &&
    grep -q 'hidutil property --set {"UserKeyMapping":\[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x700000029}\]}' "$STUB_LOG" ||
    { cat "$STUB_LOG"; return 1; }
  : >"$STUB_LOG"
  STUB_HIDUTIL_OUT="HIDKeyboardModifierMappingDst = 30064771113" "$M" defaults apply >"$SANDBOX/o" 2>&1
  ! grep -q 'hidutil property --set' "$STUB_LOG" || return 1
  printf 'capslock = none\n' >"$MACOS_DOTFILES/macos/profiles/work/system.conf"
  "$M" defaults apply >/dev/null 2>&1
  [ ! -f "$agent" ] && grep -q 'hidutil property --set {"UserKeyMapping":\[\]}' "$STUB_LOG"
}
check "Caps Lock: remap + login agent, idempotent, and removable (profile overrides base)" t_capslock

t_browser() {
  system_env
  printf 'browser = com.brave.Browser\n' >>"$MACOS_DOTFILES/macos/profiles/base/system.conf"
  "$M" defaults apply >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q '^duti -s com.brave.Browser http$' "$STUB_LOG" && grep -q '^duti -s com.brave.Browser https$' "$STUB_LOG" &&
    grep -q '^browser|' "$MACOS_STATE/pending" || { cat "$STUB_LOG"; return 1; }
  # Once the user confirms, LaunchServices records it (lowercased).
  mkdir -p "$HOME/Library/Preferences/com.apple.LaunchServices"
  cat >"$HOME/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>LSHandlers</key><array>
<dict><key>LSHandlerURLScheme</key><string>http</string><key>LSHandlerRoleAll</key><string>com.brave.browser</string></dict>
</array></dict></plist>
PLIST
  : >"$STUB_LOG"
  "$M" defaults apply >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  ! grep -q '^duti' "$STUB_LOG" && ! grep -q '^browser|' "$MACOS_STATE/pending"
}
check "default browser: set via duti, pending until confirmed, then left alone" t_browser

t_brave_policy() {
  system_env
  printf '<plist/>\n' >"$MACOS_DOTFILES/macos/profiles/base/brave.mobileconfig"
  "$M" defaults apply >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q "^open $MACOS_DOTFILES/macos/profiles/base/brave.mobileconfig" "$STUB_LOG" && grep -q '^brave-policy|' "$MACOS_STATE/pending" || return 1
  mkdir -p "$MANAGED_PREFS_DIR" && touch "$MANAGED_PREFS_DIR/com.brave.Browser.plist"
  : >"$STUB_LOG"
  "$M" defaults apply >/dev/null 2>&1
  ! grep -q '^open' "$STUB_LOG" && ! grep -q '^brave-policy|' "$MACOS_STATE/pending"
}
check "Brave policy: opened for approval once, cleared when installed" t_brave_policy

t_system_check() {
  system_env
  printf 'browser = com.brave.Browser\n' >>"$MACOS_DOTFILES/macos/profiles/base/system.conf"
  "$M" defaults check >"$SANDBOX/o" 2>&1 && return 1
  grep -q 'drift  dock:' "$SANDBOX/o" && grep -q 'drift  browser: default browser is com.apple.safari' "$SANDBOX/o" &&
    ! grep -qE '^(duti|dockutil --add|open)' "$STUB_LOG"
}
check "defaults check also reports Dock and browser drift, read-only" t_system_check

# ---------------------------------------------------------------------------
section "identity"

KEY_DEF="ssh-ed25519 AAAAC3NzaDEFAULTKEY personal"
KEY_WORK="ssh-ed25519 AAAAC3NzaWORKKEY work"
export OP_AGENT_SOCK="$SANDBOX/op/agent.sock"

identity_env() {
  dotfiles_env
  rm -rf "$HOME" && mkdir -p "$HOME/.ssh"
  printf '' >"$MACOS_DOTFILES/macos/profiles/base/stow.list"
  printf '' >"$MACOS_DOTFILES/macos/profiles/work/stow.list"
  mkdir -p "$MACOS_DOTFILES/ssh/.ssh"
  printf 'Host *\n  IdentityAgent "~/.1password/agent.sock"\n' >"$MACOS_DOTFILES/ssh/.ssh/config"
  cat >"$MACOS_DOTFILES/macos/orgs.conf" <<ORGS
# org | directory | email | github_user | signing_key | github_owners
default | ~ | me@personal.dev | ar4mirez | $KEY_DEF
cuemby  | ~/Work/Cuemby | angel@cuemby.com | ar4mirez | $KEY_WORK | cuemby cuemby-labs
ORGS
}
agent_up() {
  STUB_SSH_ADD_OUT="$(printf '%s\n%s' "$KEY_DEF" "$KEY_WORK")"
  export STUB_SSH_ADD_RC=0 STUB_SSH_ADD_OUT
}
agent_down() { export STUB_SSH_ADD_RC=2; unset STUB_SSH_ADD_OUT; }
IG="$HOME/.config/git/identity.gitconfig"

t_identity_none() {
  identity_env; printf '# nothing yet\n' >"$MACOS_DOTFILES/macos/orgs.conf"
  "$M" identity --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q 'no identities' "$SANDBOX/o" && [ ! -e "$HOME/.config/git/identity.gitconfig" ]
}
check "identity with an empty orgs.conf changes nothing" t_identity_none

t_identity_invalid() {
  identity_env
  printf 'default | ~ | other@x.dev | ar4mirez |\n' >>"$MACOS_DOTFILES/macos/orgs.conf"
  "$M" identity --yes >"$SANDBOX/o" 2>&1 && return 1
  grep -q 'org default declared twice' "$SANDBOX/o"
}
check "identity rejects an invalid orgs.conf" t_identity_invalid

t_identity_agent_down() {
  identity_env; agent_down
  "$M" identity --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  (agent_up)
  grep -q 'email = me@personal.dev' "$IG" && grep -q 'gpgsign = false' "$IG" && ! grep -q '\[gpg' "$IG" &&
    grep -q 'includeIf "gitdir:~/Work/Cuemby/"' "$IG" &&
    [ ! -e "$HOME/.ssh/config" ] && [ ! -e "$MACOS_STATE/identity.verified" ] &&
    grep -q '^1password|' "$MACOS_STATE/pending" && ! grep -q 'ssh-key add' "$STUB_LOG" || { cat "$SANDBOX/o"; return 1; }
}
check "without the 1Password agent: identities written, signing and ssh wait, pending added" t_identity_agent_down

t_identity_agent_up() {
  identity_env; agent_up
  STUB_GH_API_USER_OUT=ar4mirez "$M" identity --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  local W="$HOME/.config/git/identity.d/cuemby.gitconfig"
  grep -q 'gpgsign = true' "$IG" && grep -q "program = $OP_SSH_SIGN" "$IG" &&
    grep -q "signingkey = ssh-ed25519 AAAAC3NzaDEFAULTKEY$" "$IG" &&
    grep -q 'includeIf "hasconfig:remote.\*.url:git@github.com:cuemby-labs/\*\*"' "$IG" &&
    grep -q 'includeIf "hasconfig:remote.\*.url:https://github.com/cuemby/\*\*"' "$IG" &&
    grep -q 'email = angel@cuemby.com' "$W" && grep -q 'gpgsign = true' "$W" && ! grep -q insteadOf "$W" &&
    grep -qx 'me@personal.dev namespaces="git" ssh-ed25519 AAAAC3NzaDEFAULTKEY' "$HOME/.config/git/allowed_signers" &&
    [ "$(readlink "$HOME/.1password/agent.sock")" = "$OP_AGENT_SOCK" ] &&
    is_link_into_repo .ssh/config ssh && grep -q 'IdentityFile ~/.ssh/macos-default.pub' "$HOME/.ssh/config.d/macos-identity" &&
    [ "$(cat "$HOME/.ssh/macos-cuemby.pub")" = "ssh-ed25519 AAAAC3NzaWORKKEY" ] &&
    [ "$(grep -c '^gh ssh-key add .*--type authentication' "$STUB_LOG")" -eq 2 ] &&
    [ "$(grep -c '^gh ssh-key add .*--type signing' "$STUB_LOG")" -eq 2 ] &&
    grep -q '^gh config set git_protocol ssh' "$STUB_LOG" && [ -f "$MACOS_STATE/identity.verified" ] &&
    ! grep -q '^1password|' "$MACOS_STATE/pending" 2>/dev/null || { cat "$SANDBOX/o"; return 1; }
}
check "with the agent: signing on, ssh linked, keys uploaded, gh switched to ssh" t_identity_agent_up

t_identity_idempotent() {
  identity_env; agent_up
  STUB_GH_API_USER_OUT=ar4mirez "$M" identity --yes >/dev/null 2>&1; : >"$STUB_LOG"
  STUB_GH_API_USER_OUT=ar4mirez STUB_GH_API_USER_KEYS_OUT="$(printf '%s\n%s' "$KEY_DEF" "$KEY_WORK")" \
    STUB_GH_API_USER_SSH_SIGNING_KEYS_OUT="$(printf '%s\n%s' "$KEY_DEF" "$KEY_WORK")" STUB_GH_CONFIG_GET_OUT=ssh \
    "$M" identity --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q 'already up to date' "$SANDBOX/o" && ! grep -qE 'ssh-key add|config set' "$STUB_LOG"
}
check "identity twice changes nothing and uploads nothing" t_identity_idempotent

t_identity_key_not_in_agent() {
  identity_env; export STUB_SSH_ADD_RC=0 STUB_SSH_ADD_OUT="$KEY_DEF"
  STUB_GH_API_USER_OUT=ar4mirez "$M" identity --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q 'gpgsign = true' "$IG" && grep -q 'gpgsign = false' "$HOME/.config/git/identity.d/cuemby.gitconfig" &&
    grep -q 'cuemby: signing key is not in the 1Password agent' "$SANDBOX/o"
}
check "an org whose key is not in the agent stays unsigned, with a warning" t_identity_key_not_in_agent

t_identity_other_account() {
  identity_env; agent_up
  sed -i '' 's/| angel@cuemby.com | ar4mirez |/| angel@cuemby.com | angel-cuemby |/' "$MACOS_DOTFILES/macos/orgs.conf"
  STUB_GH_API_USER_OUT=ar4mirez "$M" identity --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q 'insteadOf = git@github.com:' "$HOME/.config/git/identity.d/cuemby.gitconfig" &&
    grep -q '^Host github.com-cuemby' "$HOME/.ssh/config.d/macos-identity" &&
    grep -q '^github-keys-cuemby|' "$MACOS_STATE/pending" &&
    [ "$(grep -c '^gh ssh-key add' "$STUB_LOG")" -eq 2 ]
}
check "a second GitHub account gets an ssh alias and a pending key upload" t_identity_other_account

t_identity_real_git_resolution() {
  identity_env; agent_up
  STUB_GH_API_USER_OUT=ar4mirez "$M" identity --yes >/dev/null 2>&1
  printf '[include]\n\tpath = ~/.config/git/identity.gitconfig\n' >"$HOME/.config/git/config"
  mkdir -p "$HOME/Work/Cuemby/app" "$HOME/code/other" "$HOME/code/viaremote"
  local g="env -u XDG_CONFIG_HOME -u GIT_CONFIG_GLOBAL /usr/bin/git"
  $g -C "$HOME/Work/Cuemby/app" init -q && $g -C "$HOME/code/other" init -q && $g -C "$HOME/code/viaremote" init -q
  $g -C "$HOME/code/viaremote" remote add origin git@github.com:cuemby-labs/tool.git
  [ "$($g -C "$HOME/Work/Cuemby/app" config user.email)" = angel@cuemby.com ] &&
    [ "$($g -C "$HOME/code/other" config user.email)" = me@personal.dev ] &&
    [ "$($g -C "$HOME/code/viaremote" config user.email)" = angel@cuemby.com ] &&
    [ "$($g -C "$HOME/code/other" config gpg.format)" = ssh ] &&
    [ "$($g -C "$HOME/Work/Cuemby/app" config user.signingkey)" = "ssh-ed25519 AAAAC3NzaWORKKEY" ]
}
check "real git picks the org identity by directory and by remote URL" t_identity_real_git_resolution

t_identity_agent_titles() {
  identity_env; agent_up
  sed -i '' "s#| $KEY_DEF#| agent:GitHub personal#; s#| $KEY_WORK |#| agent:GitHub Cuemby |#" "$MACOS_DOTFILES/macos/orgs.conf"
  STUB_SSH_ADD_OUT="$(printf 'ssh-ed25519 AAAAC3NzaDEFAULTKEY GitHub personal\nssh-ed25519 AAAAC3NzaWORKKEY GitHub Cuemby')" \
    STUB_GH_API_USER_OUT=ar4mirez "$M" identity --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q 'signingkey = ssh-ed25519 AAAAC3NzaDEFAULTKEY$' "$IG" &&
    grep -q 'signingkey = ssh-ed25519 AAAAC3NzaWORKKEY$' "$HOME/.config/git/identity.d/cuemby.gitconfig" &&
    grep -q 'gpgsign = true' "$HOME/.config/git/identity.d/cuemby.gitconfig" || { cat "$SANDBOX/o"; return 1; }
}
check "signing_key agent:<title> resolves to the 1Password key with that title" t_identity_agent_titles

t_identity_agent_title_missing() {
  identity_env; agent_up
  sed -i '' "s#| $KEY_WORK |#| agent:No Such Key |#" "$MACOS_DOTFILES/macos/orgs.conf"
  STUB_GH_API_USER_OUT=ar4mirez "$M" identity --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q "cuemby: no key titled 'No Such Key'" "$SANDBOX/o" && grep -q 'gpgsign = false' "$HOME/.config/git/identity.d/cuemby.gitconfig"
}
check "an unknown agent: title leaves that org unsigned, with a warning" t_identity_agent_title_missing

t_identity_blocked_hint() {
  identity_env; agent_down
  # A directory we cannot list stands in for macOS privacy protection.
  mkdir -p "$SANDBOX/op" && chmod 000 "$SANDBOX/op"
  local fakels="$SANDBOX/fakels"; mkdir -p "$fakels"
  printf '#!/bin/bash\necho "ls: $1: Operation not permitted" >&2\nexit 1\n' >"$fakels/ls"; chmod +x "$fakels/ls"
  PATH="$fakels:$PATH" "$M" identity --yes >"$SANDBOX/o" 2>&1
  chmod 755 "$SANDBOX/op"
  grep -q "macOS is blocking access to 1Password's data folder" "$SANDBOX/o" || { cat "$SANDBOX/o"; return 1; }
}
check "identity explains a macOS privacy block on 1Password's folder" t_identity_blocked_hint

t_doctor_ssh_greeting() {
  identity_env; agent_up
  STUB_GH_API_USER_OUT=ar4mirez "$M" identity --yes >/dev/null 2>&1
  ( STUB_SSH_RC=1 STUB_SSH_OUT="Hi ar4mirez! You've successfully authenticated, but GitHub does not provide shell access." \
      "$M" doctor >"$SANDBOX/o" 2>&1 )
  grep -q 'ok    ssh to GitHub authenticates through 1Password' "$SANDBOX/o" || { cat "$SANDBOX/o"; return 1; }
}
check "doctor accepts GitHub's ssh greeting although ssh -T exits 1" t_doctor_ssh_greeting

t_identity_known_hosts() {
  identity_env; agent_up
  local meta; meta="$(printf 'ssh-ed25519 AAAAhostkeyED\necdsa-sha2-nistp256 AAAAhostkeyEC')"
  STUB_GH_API_USER_OUT=ar4mirez STUB_GH_API_META_OUT="$meta" "$M" identity --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -qx 'github.com ssh-ed25519 AAAAhostkeyED' "$HOME/.ssh/known_hosts" &&
    grep -qx 'github.com ecdsa-sha2-nistp256 AAAAhostkeyEC' "$HOME/.ssh/known_hosts" || { cat "$SANDBOX/o"; return 1; }
  STUB_GH_API_USER_OUT=ar4mirez STUB_GH_API_META_OUT="$meta" "$M" identity --yes >"$SANDBOX/o" 2>&1
  [ "$(wc -l <"$HOME/.ssh/known_hosts" | tr -d ' ')" -eq 2 ] && grep -q 'GitHub host keys already known' "$SANDBOX/o"
}
check "identity pins GitHub's host keys from its API, once" t_identity_known_hosts

t_identity_default_order() {
  identity_env; agent_up
  # default listed AFTER the org must not override the org's includeIf.
  { grep -v '^default' "$MACOS_DOTFILES/macos/orgs.conf"; grep '^default' "$MACOS_DOTFILES/macos/orgs.conf"; } >"$SANDBOX/orgs" &&
    mv "$SANDBOX/orgs" "$MACOS_DOTFILES/macos/orgs.conf"
  STUB_GH_API_USER_OUT=ar4mirez "$M" identity --yes >/dev/null 2>&1
  printf '[include]\n\tpath = ~/.config/git/identity.gitconfig\n' >"$HOME/.config/git/config"
  mkdir -p "$HOME/Work/Cuemby/app"
  local g="env -u XDG_CONFIG_HOME -u GIT_CONFIG_GLOBAL /usr/bin/git"
  $g -C "$HOME/Work/Cuemby/app" init -q
  [ "$($g -C "$HOME/Work/Cuemby/app" config user.email)" = angel@cuemby.com ]
}
check "the org identity wins even when default comes later in orgs.conf" t_identity_default_order

t_identity_keeps_verified_setup() {
  identity_env; agent_up
  STUB_GH_API_USER_OUT=ar4mirez "$M" identity --yes >/dev/null 2>&1
  cp "$IG" "$SANDBOX/ig.before"
  agent_down
  "$M" apply </dev/null >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  cmp -s "$IG" "$SANDBOX/ig.before" && grep -q 'gpgsign = true' "$IG" && grep -q 'keeping the verified identity setup' "$SANDBOX/o"
}
check "apply with 1Password closed keeps a verified signing setup" t_identity_keeps_verified_setup

t_identity_no_alias_without_key() {
  identity_env; agent_up
  sed -i '' "s#| angel@cuemby.com | ar4mirez | $KEY_WORK |#| angel@cuemby.com | angel-cuemby | agent:Missing |#" "$MACOS_DOTFILES/macos/orgs.conf"
  STUB_GH_API_USER_OUT=ar4mirez "$M" identity --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  ! grep -q insteadOf "$HOME/.config/git/identity.d/cuemby.gitconfig" && ! grep -q 'github.com-cuemby' "$HOME/.ssh/config.d/macos-identity"
}
check "no url rewrite for a second account whose key is unresolved (no alias exists)" t_identity_no_alias_without_key

t_apply_never_waits_for_agent() {
  identity_env; agent_down
  "$M" apply </dev/null >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q '1Password SSH agent is not answering' "$SANDBOX/o" && ! grep -q '^open -a 1Password' "$STUB_LOG"
}
check "apply renders identities but never waits on 1Password" t_apply_never_waits_for_agent

# ---------------------------------------------------------------------------
section "migrations and update"

migrations_env() {
  phase3_env
  rm -rf "$MACOS_MIGRATIONS_DIR" && mkdir -p "$MACOS_MIGRATIONS_DIR"
  for n in 200 100; do
    printf 'echo "ran %s $MACOS_PROFILE" >>"%s/mig.log"\n' "$n" "$SANDBOX" >"$MACOS_MIGRATIONS_DIR/$n.sh"
  done
  rm -f "$SANDBOX/mig.log"
}

t_update_runs_migrations_then_apply() {
  migrations_env
  "$M" update --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  [ "$(cat "$SANDBOX/mig.log")" = "$(printf 'ran 100 work\nran 200 work')" ] &&
    [ -f "$MACOS_STATE/migrations/100" ] && [ -f "$MACOS_STATE/migrations/200" ] &&
    grep -q 'apply finished' "$SANDBOX/o" && ! grep -q 'in progress' "$SANDBOX/o" &&
    [ "$(readlink "$HOME/.local/bin/macos")" = "$ROOT/bin/macos" ] || { cat "$SANDBOX/o"; return 1; }
  "$M" update --yes >"$SANDBOX/o" 2>&1 && [ "$(wc -l <"$SANDBOX/mig.log" | tr -d ' ')" -eq 2 ] && grep -q 'no pending migrations' "$SANDBOX/o"
}
check "update runs pending migrations once, in order, then apply" t_update_runs_migrations_then_apply

t_migration_failure_stops() {
  migrations_env
  printf 'exit 3\n' >"$MACOS_MIGRATIONS_DIR/150.sh"
  "$M" update --yes >"$SANDBOX/o" 2>&1 && return 1
  grep -q 'migration 150.sh failed' "$SANDBOX/o" && [ -f "$MACOS_STATE/migrations/100" ] &&
    [ ! -f "$MACOS_STATE/migrations/150" ] && [ ! -f "$MACOS_STATE/migrations/200" ] && ! grep -q 'ran 200' "$SANDBOX/mig.log"
}
check "a failing migration stops before later ones and stays pending" t_migration_failure_stops

# Real git against local bare remotes, run from a copy of the engine so the
# real clone is never fetched or merged.
REALGIT="$SANDBOX/realgit"
mkdir -p "$REALGIT" && ln -sf /usr/bin/git "$REALGIT/git"
G() { /usr/bin/git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

update_realgit_env() {
  migrations_env
  local eng="$SANDBOX/eng"
  rm -rf "$eng" "$SANDBOX/eng.git" "$SANDBOX/dot.git" "$SANDBOX/dot-other"
  cp -R "$ROOT" "$eng" && ENG="$(cd "$eng" && pwd -P)"
  G clone -q --bare "$ENG" "$SANDBOX/eng.git"
  G -C "$ENG" remote set-url origin "$SANDBOX/eng.git" && G -C "$ENG" fetch -q
  G -C "$ENG" branch -q -u origin/main main 2>/dev/null || G -C "$ENG" branch -q -u "origin/$(G -C "$ENG" branch --show-current)"
  # dotfiles: a real repo with an upstream
  rm -rf "$MACOS_DOTFILES/.git"
  printf 'one\n' >"$MACOS_DOTFILES/notes.txt"
  G init -q -b main "$MACOS_DOTFILES" && G -C "$MACOS_DOTFILES" add -A && G -C "$MACOS_DOTFILES" commit -qm base
  G init -q --bare -b main "$SANDBOX/dot.git"
  G -C "$MACOS_DOTFILES" remote add origin "$SANDBOX/dot.git" && G -C "$MACOS_DOTFILES" push -q -u origin main 2>/dev/null
  G clone -q "$SANDBOX/dot.git" "$SANDBOX/dot-other"
  printf 'upstream\n' >"$SANDBOX/dot-other/notes.txt"
  G -C "$SANDBOX/dot-other" commit -qam upstream && G -C "$SANDBOX/dot-other" push -q
}

t_update_rebases_dotfiles() {
  update_realgit_env
  printf 'mine\n' >"$MACOS_DOTFILES/local-only.txt"
  G -C "$MACOS_DOTFILES" add local-only.txt   # an uncommitted, non-conflicting edit
  PATH="$REALGIT:$PATH" "$ENG/bin/macos" update --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  [ "$(cat "$MACOS_DOTFILES/notes.txt")" = upstream ] && [ "$(cat "$MACOS_DOTFILES/local-only.txt")" = mine ] &&
    grep -q 'apply finished' "$SANDBOX/o"
}
check "update pulls dotfiles (real git) keeping uncommitted edits, then applies" t_update_rebases_dotfiles

t_update_autostash_conflict() {
  update_realgit_env
  printf 'local edit\n' >"$MACOS_DOTFILES/notes.txt"   # conflicts with upstream
  PATH="$REALGIT:$PATH" "$ENG/bin/macos" update --yes >"$SANDBOX/o" 2>&1 && { cat "$SANDBOX/o"; return 1; }
  grep -q 'saved in the stash' "$SANDBOX/o" && ! grep -q 'apply finished' "$SANDBOX/o" &&
    [ "$(cat "$MACOS_DOTFILES/notes.txt")" = upstream ] && ! grep -q '<<<<<<<' "$MACOS_DOTFILES/notes.txt" &&
    [ "$(G -C "$MACOS_DOTFILES" stash list | wc -l | tr -d ' ')" -eq 1 ] &&
    G -C "$MACOS_DOTFILES" stash show -p | grep -q '+local edit' || { cat "$SANDBOX/o"; return 1; }
}
check "update stops on an autostash conflict: no markers left, edits kept in the stash, nothing applied" t_update_autostash_conflict

t_update_dry_run() {
  migrations_env
  STUB_GIT_OUT="abc1234 an incoming commit" "$M" update --dry-run >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  ! grep -qE ' (merge|rebase) ' "$STUB_LOG" && [ ! -f "$SANDBOX/mig.log" ] && [ ! -d "$MACOS_STATE/migrations" ] &&
    grep -q 'would run: .*100.sh' "$SANDBOX/o" && grep -q 'apply finished (dry run)' "$SANDBOX/o"
}
check "update --dry-run only previews" t_update_dry_run

t_bootstrap_marks_migrations() {
  bootstrap_env
  rm -rf "$MACOS_MIGRATIONS_DIR" && mkdir -p "$MACOS_MIGRATIONS_DIR" && printf 'touch "%s/ran"\n' "$SANDBOX" >"$MACOS_MIGRATIONS_DIR/100.sh"
  rm -f "$SANDBOX/ran"
  STUB_GH_OUT="  - Token scopes: 'admin:public_key', 'admin:ssh_signing_key'" \
    "$M" bootstrap --yes --profile work --hostname x >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  [ -f "$MACOS_STATE/migrations/100" ] && [ ! -f "$SANDBOX/ran" ] && grep -q '==> Health check' "$SANDBOX/o"
}
check "a fresh bootstrap marks migrations done without running them" t_bootstrap_marks_migrations

t_bootstrap_rerun_runs_migrations() {
  bootstrap_env
  rm -rf "$MACOS_MIGRATIONS_DIR" && mkdir -p "$MACOS_MIGRATIONS_DIR" && printf 'touch "%s/ran"\n' "$SANDBOX" >"$MACOS_MIGRATIONS_DIR/100.sh"
  rm -f "$SANDBOX/ran"
  mkdir -p "$MACOS_STATE" && printf 'MACOS_PROFILE="work"\n' >"$MACOS_STATE/machine.env"   # set up before: not fresh
  STUB_GH_OUT="  - Token scopes: 'admin:public_key', 'admin:ssh_signing_key'" \
    "$M" bootstrap --yes --profile work --hostname x >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  [ -f "$SANDBOX/ran" ] && [ -f "$MACOS_STATE/migrations/100" ]
}
check "re-running bootstrap on a set-up Mac runs pending migrations (not marks them)" t_bootstrap_rerun_runs_migrations

t_bootstrap_unreadable_scopes() {
  bootstrap_env
  STUB_GH_OUT="" "$M" bootstrap --yes --profile work --hostname x >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q "can't read gh token scopes" "$SANDBOX/o" && ! grep -q 'lacks scopes' "$SANDBOX/o"
}
check "a gh token with no readable scopes (fine-grained) warns instead of stopping" t_bootstrap_unreadable_scopes

t_apply_continues_after_brew_failure() {
  dotfiles_env
  STUB_BREW_BUNDLE_CHECK_RC=1 STUB_BREW_BUNDLE_INSTALL_RC=1 "$M" apply >"$SANDBOX/o" 2>&1 && return 1
  grep -q 'some apps failed to install' "$SANDBOX/o" && is_link_into_repo .zshrc zsh &&
    grep -q '==> Defaults' "$SANDBOX/o" && grep -q 'apply finished with errors in: apps' "$SANDBOX/o"
}
check "a failed brew install still converges dotfiles and defaults, then exits non-zero" t_apply_continues_after_brew_failure

# ---------------------------------------------------------------------------
section "uninstall"

t_uninstall() {
  dotfiles_env
  local copy="$SANDBOX/engine-copy"
  rm -rf "$copy" && cp -R "$ROOT" "$copy" && copy="$(cd "$copy" && pwd -P)"
  "$copy/bin/macos" dotfiles link >/dev/null 2>&1
  mkdir -p "$HOME/.local/bin" && ln -sfn "$copy/bin/macos" "$HOME/.local/bin/macos"
  mkdir -p "$MACOS_STATE/backup/20260101-000000" "$MACOS_STATE/backup/20260101-000000-retired-key/.ssh"
  echo original >"$MACOS_STATE/backup/20260101-000000/.zshrc"
  echo secret >"$MACOS_STATE/backup/20260101-000000-retired-key/.ssh/id_ed25519"
  mkdir -p "$HOME/.config/git/identity.d" "$HOME/.ssh/config.d"
  touch "$HOME/.config/git/identity.gitconfig" "$HOME/.config/git/identity.d/x.gitconfig" "$HOME/.ssh/config.d/macos-identity" "$HOME/.ssh/macos-default.pub"
  "$copy/bin/macos" uninstall --yes >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  [ ! -e "$copy" ] && [ ! -L "$HOME/.local/bin/macos" ] && [ -f "$MACOS_DOTFILES/zsh/.zshrc" ] &&
    [ ! -L "$HOME/.zshrc" ] && [ "$(cat "$HOME/.zshrc")" = original ] &&
    [ ! -e "$HOME/.ssh/id_ed25519" ] &&
    [ ! -e "$HOME/.config/git/identity.gitconfig" ] && [ ! -d "$HOME/.config/git/identity.d" ] &&
    [ ! -e "$HOME/.ssh/config.d/macos-identity" ] && [ ! -e "$HOME/.ssh/macos-default.pub" ] || { cat "$SANDBOX/o"; ls -la "$HOME"; return 1; }
}
check "uninstall unlinks, restores the replaced files, removes generated identity files and the engine" t_uninstall

t_uninstall_guard() {
  dotfiles_env
  local copy="$SANDBOX/not-an-engine"
  rm -rf "$copy" && cp -R "$ROOT" "$copy" && rm -rf "$copy/.git"
  "$copy/bin/macos" uninstall --yes >"$SANDBOX/o" 2>&1 && return 1
  [ -d "$copy" ] && grep -q 'does not look like an engine clone' "$SANDBOX/o"
}
check "uninstall refuses to delete a directory that is not an engine clone" t_uninstall_guard

t_uninstall_dry_run() {
  dotfiles_env
  local copy="$SANDBOX/engine-copy2"
  rm -rf "$copy" && cp -R "$ROOT" "$copy" && copy="$(cd "$copy" && pwd -P)"
  "$copy/bin/macos" uninstall --dry-run >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  [ -d "$copy" ] && grep -q "would run: rm -rf $copy" "$SANDBOX/o"
}
check "uninstall --dry-run removes nothing" t_uninstall_dry_run

# ---------------------------------------------------------------------------
section "doctor"

doctor_env() {
  dotfiles_env
  "$M" dotfiles link >/dev/null 2>&1
  printf 'auth sufficient pam_tid.so\n' >"$PAM_SUDO_LOCAL"
  mkdir -p "$HOME/.local/bin" && ln -sfn "$ROOT/bin/macos" "$HOME/.local/bin/macos"
  export STUB_FDESETUP_OUT="FileVault is On." STUB_CSRUTIL_OUT="System Integrity Protection status: enabled."
  export STUB_SOCKETFILTERFW_OUT="Firewall is enabled. (State = 1)" STUB_BREW_LIST___CASK_RC=1
  : >"$STUB_LOG"
}

t_doctor_healthy() {
  doctor_env
  ( "$M" doctor >"$SANDBOX/o" 2>&1 ) || { cat "$SANDBOX/o"; return 1; }
  grep -q ' 0 failures' "$SANDBOX/o" && grep -q 'ok    FileVault on' "$SANDBOX/o" &&
    grep -q 'ok    every declared app is installed' "$SANDBOX/o" && grep -q 'ok    all .* dotfiles linked' "$SANDBOX/o"
}
check "doctor passes on a healthy machine" t_doctor_healthy

t_doctor_failures() {
  doctor_env
  rm "$HOME/.zshrc"
  (
    STUB_FDESETUP_OUT="FileVault is Off." STUB_BREW_BUNDLE_CHECK_RC=1 STUB_BREW_BUNDLE_CHECK_OUT="→ Cask slack needs to be installed." \
      "$M" doctor >"$SANDBOX/o" 2>&1
  ) && return 1
  grep -q 'FAIL  FileVault is off' "$SANDBOX/o" && grep -q 'FAIL  declared but not installed: slack' "$SANDBOX/o" &&
    grep -q 'FAIL  not linked: ~/.zshrc' "$SANDBOX/o" && grep -q ' 3 failures' "$SANDBOX/o" || { cat "$SANDBOX/o"; return 1; }
}
check "doctor fails on FileVault off, missing apps, unlinked dotfiles" t_doctor_failures

t_doctor_pending() {
  doctor_env
  printf 'tailscale|Log in to Tailscale\nbrowser|Confirm browser\nother|Do the other thing\n' >"$MACOS_STATE/pending"
  ( STUB_TAILSCALE_CLI_RC=0 "$M" doctor >"$SANDBOX/o" 2>&1 ) || { cat "$SANDBOX/o"; return 1; }
  grep -q 'warn  Do the other thing' "$SANDBOX/o" && ! grep -q 'Log in to Tailscale' "$SANDBOX/o" &&
    [ "$(cat "$MACOS_STATE/pending")" = "other|Do the other thing" ]
}
check "doctor lists pending steps and clears the ones that are visibly done" t_doctor_pending

t_doctor_claude_code_cask() {
  doctor_env
  ( STUB_BREW_LIST___CASK_RC=0 "$M" doctor >"$SANDBOX/o" 2>&1 ) && return 1
  grep -q 'claude-code cask is installed' "$SANDBOX/o"
}
check "doctor flags the claude-code cask shadowing the native install" t_doctor_claude_code_cask

t_doctor_intel_scan() {
  doctor_env
  local A="$SANDBOX/Applications"
  rm -rf "$A" && for n in Native Script Intel; do
    mkdir -p "$A/$n.app/Contents/MacOS"
    plutil -create xml1 "$A/$n.app/Contents/Info.plist" && plutil -insert CFBundleExecutable -string "$n" "$A/$n.app/Contents/Info.plist"
    printf 'x\n' >"$A/$n.app/Contents/MacOS/$n"
  done
  # lipo stub: one answer per run; run doctor once per case.
  ( MACOS_APPLICATIONS_DIRS="$A" STUB_LIPO_RC=1 "$M" doctor >"$SANDBOX/o1" 2>&1 )
  ( MACOS_APPLICATIONS_DIRS="$A" STUB_LIPO_OUT="x86_64" "$M" doctor >"$SANDBOX/o2" 2>&1 )
  grep -q 'every app runs natively' "$SANDBOX/o1" && grep -q 'Intel-only apps .*Native' "$SANDBOX/o2" || { cat "$SANDBOX/o1" "$SANDBOX/o2"; return 1; }
}
check "doctor's Intel-only scan ignores non-Mach-O launchers and flags x86-only binaries" t_doctor_intel_scan

t_doctor_signing() {
  doctor_env
  identity_env; agent_up
  STUB_GH_API_USER_OUT=ar4mirez "$M" identity --yes >/dev/null 2>&1
  printf '[include]\n\tpath = ~/.config/git/identity.gitconfig\n' >"$HOME/.config/git/config"
  ( PATH="$REALGIT:$PATH" "$M" doctor >"$SANDBOX/o" 2>&1 )
  grep -q 'ok    commits are signed through 1Password' "$SANDBOX/o" || { cat "$SANDBOX/o"; return 1; }
  export STUB_SSH_ADD_OUT="$KEY_WORK"   # the default signing key is gone from the agent
  ( PATH="$REALGIT:$PATH" "$M" doctor >"$SANDBOX/o" 2>&1 ) && return 1
  grep -q 'FAIL  commit signing is on but its key is not in the 1Password agent' "$SANDBOX/o"
}
check "doctor verifies commit signing: signer present and key in the agent" t_doctor_signing

t_logs_private() {
  dotfiles_env
  "$M" apply >/dev/null 2>&1
  [ "$(stat -f %Lp "$(ls "$MACOS_STATE"/logs/*apply.log | head -1)")" = 600 ] && [ "$(stat -f %Lp "$MACOS_STATE/logs")" = 700 ]
}
check "log files are private (0600 in a 0700 dir)" t_logs_private

t_flags_without_action() {
  defaults_env
  "$M" defaults --dry-run >"$SANDBOX/o" 2>&1
  ! grep -q 'unknown action' "$SANDBOX/o"
}
check "commands with a default action accept options alone (macos defaults --dry-run)" t_flags_without_action

t_doctor_no_profile() {
  phase3_env; rm -f "$MACOS_STATE/machine.env"
  ( "$M" doctor >"$SANDBOX/o" 2>&1 ) && return 1
  grep -q "FAIL  no profile" "$SANDBOX/o"
}
check "doctor fails clearly before bootstrap" t_doctor_no_profile

# ---------------------------------------------------------------------------
section "boot.sh"

BOOT="$ROOT/boot.sh"

t_boot_refuses_intel() {
  STUB_UNAME_M=x86_64 /bin/bash "$BOOT" >"$SANDBOX/o" 2>&1 && return 1
  grep -q 'Apple silicon Macs only' "$SANDBOX/o"
}
check "boot.sh refuses non-arm64" t_boot_refuses_intel

t_boot_hands_over() {
  local root="$SANDBOX/engine"
  rm -rf "$root"; mkdir -p "$root/.git" "$root/bin"
  printf '#!/bin/bash\necho "macos $*" >>"$STUB_LOG"\n' >"$root/bin/macos"; chmod +x "$root/bin/macos"
  : >"$STUB_LOG"; : >"$SANDBOX/tty"
  MACOS_ROOT="$root" MACOS_TTY="$SANDBOX/tty" /bin/bash "$BOOT" --profile work >"$SANDBOX/o" 2>&1 || { cat "$SANDBOX/o"; return 1; }
  grep -q "^git -c credential.helper= -C $root pull --ff-only" "$STUB_LOG" &&
    grep -qx 'macos bootstrap --profile work' "$STUB_LOG" &&
    ! grep -q '^curl' "$STUB_LOG"
}
check "boot.sh updates the engine and hands args to macos bootstrap" t_boot_hands_over

t_boot_clones() {
  local root="$SANDBOX/engine2"
  rm -rf "$root"; : >"$STUB_LOG"
  MACOS_ROOT="$root" MACOS_TTY="$SANDBOX/tty" /bin/bash "$BOOT" >/dev/null 2>&1
  grep -q "^git -c credential.helper= clone --quiet --branch main https://github.com/ar4mirez/macos.git $root" "$STUB_LOG"
}
check "boot.sh clones the engine on a fresh machine" t_boot_clones

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  printf "Failed:$failed\n"
  exit 1
fi
