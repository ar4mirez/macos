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

STUBBED_TOOLS="defaults killall osascript scutil sudo brew mas dockutil duti softwareupdate stow hidutil pmset gh op git curl xcode-select uname mise"

REAL_HOME="$HOME"
export HOME="$SANDBOX/home"
export MACOS_STATE="$SANDBOX/state"
export MACOS_DOTFILES="$SANDBOX/dotfiles"
export STUB_LOG="$SANDBOX/stub.log"
export NO_COLOR=1
unset XDG_STATE_HOME MACOS_PROFILE MACOS_BASH
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
  MACOS_BASH="$BASH4" "$M" defaults >"$SANDBOX/o" 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && grep -q 'not implemented' "$SANDBOX/o"
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
  STUB_BREW_BUNDLE_CHECK_RC=1 STUB_GH_OUT="  - Token scopes: 'admin:public_key', 'admin:ssh_signing_key', 'repo'" \
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
check "bootstrap --yes runs phases 1–6 in order with the right commands" t_bootstrap_full

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
