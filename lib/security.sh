# shellcheck shell=bash
# Security baseline: Touch ID for sudo, application firewall, Homebrew
# analytics, hostname. Each function is idempotent and dry-run aware.
# bash-3.2-safe. Requires lib/common.sh and lib/run.sh.

# pam-reattach (from Homebrew) lets Touch ID work inside tmux. sudo loads PAM
# modules as root, so sudo_local references a root-owned copy of it, never
# the user-writable Homebrew prefix (and uninstalling the formula later
# cannot break sudo).
reattach_src() { printf '%s\n' "$HOMEBREW_PREFIX/lib/pam/pam_reattach.so"; }

# touchid_render — desired /etc/pam.d/sudo_local. pam_reattach must come
# before pam_tid.
touchid_render() {
  printf '# sudo_local: managed by ar4mirez/macos; survives macOS updates.\n'
  if [ -f "$(reattach_src)" ] || [ -f "$PAM_REATTACH_DEST" ]; then
    printf 'auth       optional       %s\n' "$PAM_REATTACH_DEST"
  fi
  printf 'auth       sufficient     pam_tid.so\n'
}

# reattach_install — keep the root-owned copy current with Homebrew's.
reattach_install() {
  local src
  src="$(reattach_src)"
  [ -f "$src" ] || return 0
  if [ -f "$PAM_REATTACH_DEST" ] && cmp -s "$src" "$PAM_REATTACH_DEST"; then
    return 0
  fi
  run sudo mkdir -p "$(dirname "$PAM_REATTACH_DEST")"
  run sudo install -o root -g wheel -m 444 "$src" "$PAM_REATTACH_DEST"
  ok "pam_reattach installed root-owned at $PAM_REATTACH_DEST"
}

# touchid_state — ok, or drift (sudo_local or the module copy out of date).
touchid_state() {
  if [ "$(cat "$PAM_SUDO_LOCAL" 2>/dev/null)" != "$(touchid_render)" ]; then
    echo "drift sudo_local"
  elif [ -f "$(reattach_src)" ] && ! cmp -s "$(reattach_src)" "$PAM_REATTACH_DEST"; then
    echo "drift pam_reattach copy"
  else
    echo ok
  fi
}

security_touchid() {
  local want backup
  reattach_install
  want="$(touchid_render)"
  if [ -f "$PAM_SUDO_LOCAL" ] && [ "$(cat "$PAM_SUDO_LOCAL")" = "$want" ]; then
    skip "Touch ID for sudo already enabled"
    return 0
  fi
  if [ -f "$PAM_SUDO_LOCAL" ] && ! grep -q 'managed by ar4mirez/macos' "$PAM_SUDO_LOCAL"; then
    # Not a <timestamp> dir: uninstall restores only dotfiles backups.
    backup="$MACOS_STATE/backup/system-$(date +%Y%m%d-%H%M%S)/sudo_local"
    run mkdir -p "$(dirname "$backup")"
    run cp "$PAM_SUDO_LOCAL" "$backup"
    warn "existing $PAM_SUDO_LOCAL backed up to $backup"
  fi
  printf '%s\n' "$want" | sudo_write_file "$PAM_SUDO_LOCAL"
  run sudo chmod 444 "$PAM_SUDO_LOCAL"
  if dry_run || [ "$(cat "$PAM_SUDO_LOCAL" 2>/dev/null)" = "$want" ]; then
    ok "Touch ID for sudo enabled"
  else
    warn "Touch ID for sudo: $PAM_SUDO_LOCAL did not take the new content"
  fi
}

security_firewall() {
  if "$SOCKETFILTERFW" --getglobalstate 2>/dev/null | grep -q 'is enabled'; then
    skip "firewall already on"
  else
    run sudo "$SOCKETFILTERFW" --setglobalstate on >/dev/null
    ok "firewall on"
  fi
  if "$SOCKETFILTERFW" --getstealthmode 2>/dev/null | grep -q 'mode is on'; then
    skip "firewall stealth mode already on"
  else
    run sudo "$SOCKETFILTERFW" --setstealthmode on >/dev/null
    ok "firewall stealth mode on"
  fi
}

security_analytics() {
  # lib/brew.sh exports HOMEBREW_NO_ANALYTICS for our own brew calls, which
  # makes `brew analytics state` report "disabled"; ask about the real setting.
  if env -u HOMEBREW_NO_ANALYTICS brew analytics state 2>/dev/null | grep -q 'analytics are disabled'; then
    skip "Homebrew analytics already off"
  else
    run brew analytics off
    ok "Homebrew analytics off"
  fi
}

# hostname_local <name> — LocalHostName form: letters, digits and hyphens.
hostname_local() {
  printf '%s' "$1" | sed "s/[’']//g" | LC_ALL=C tr -cs 'A-Za-z0-9-' '-' | sed 's/^-*//; s/-*$//'
}

security_hostname() { # security_hostname <name>
  local name="$1" local_name key want cur
  local_name="$(hostname_local "$name")"
  [ -n "$local_name" ] || die "hostname '$name' has no usable characters"
  for key in ComputerName LocalHostName HostName; do
    if [ "$key" = ComputerName ]; then want="$name"; else want="$local_name"; fi
    cur="$(scutil --get "$key" 2>/dev/null || true)"
    if [ "$cur" = "$want" ]; then
      skip "$key already $want"
    else
      run sudo scutil --set "$key" "$want"
      ok "$key → $want"
    fi
  done
}
