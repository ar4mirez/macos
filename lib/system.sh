# shellcheck shell=bash
# System settings that are not single `defaults` keys: Dock layout, Caps Lock
# remap, default browser, Brave policy profile. Each has a *_state function
# (prints "ok" or "drift <detail>") and an apply function that is idempotent
# and dry-run aware. bash-3.2-safe. Requires lib/common.sh, lib/run.sh,
# lib/profile.sh and lib/pending.sh.

# system_setting <key> [default] — from system.conf, profile overriding base.
system_setting() {
  local p f v="" line
  for p in $(active_profiles); do
    f="$(profiles_dir)/$p/system.conf"
    [ -f "$f" ] || continue
    line="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$f" | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//' | tail -n 1)"
    [ -n "$line" ] && v="$line"
  done
  printf '%s\n' "${v:-${2:-}}"
}

# profile_file <name> — the last active profile's copy of a file (profile
# replaces base), or nothing.
profile_file() {
  local p f=""
  for p in $(active_profiles); do
    [ -f "$(profiles_dir)/$p/$1" ] && f="$(profiles_dir)/$p/$1"
  done
  if [ -n "$f" ]; then
    printf '%s\n' "$f"
  fi
}

# --- Dock ------------------------------------------------------------------

# dock_wanted — declared app paths that exist on this Mac, in order.
dock_wanted() {
  local f line
  f="$(profile_file dock.conf)" || return 0
  [ -n "$f" ] || return 0
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed 's/[[:space:]]*#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$line" ] || continue
    if [ -e "$line" ]; then
      printf '%s\n' "$line"
    else
      warn "Dock: $line is not installed; skipping it" >&2
    fi
  done <"$f"
}

# dock_current — "path<TAB>id" of the Dock's apps, in order (id is the
# bundle id, or the label when there is none).
dock_current() {
  local label url section id path
  dockutil --list 2>/dev/null | while IFS="$(printf '\t')" read -r label url section _ id; do
    [ "$section" = persistentApps ] || continue
    path="${url#file://}"
    path="${path%/}"
    path="$(printf '%b' "${path//%/\\x}")"
    printf '%s\t%s\n' "$path" "${id:-$label}"
  done
}

# _dock_norm — resolve paths so /Applications/Safari.app and its Cryptex
# location compare equal.
_dock_norm() {
  local p
  while IFS= read -r p; do
    readlink -f "$p" 2>/dev/null || printf '%s\n' "$p"
  done
}

dock_state() {
  [ -n "$(profile_file dock.conf)" ] || { echo ok; return; }
  if [ "$(dock_wanted 2>/dev/null | _dock_norm)" = "$(dock_current | cut -f1 | _dock_norm)" ]; then
    echo ok
  else
    echo "drift Dock apps differ from dock.conf"
  fi
}

dock_apply() {
  local path id wanted
  if [ -z "$(profile_file dock.conf)" ]; then
    skip "no dock.conf; leaving the Dock alone"
    return 0
  fi
  if [ "$(dock_state)" = ok ]; then
    skip "Dock already matches dock.conf"
    return 0
  fi
  wanted="$(dock_wanted)"
  dock_current | while IFS="$(printf '\t')" read -r path id; do
    run dockutil --remove "$id" --no-restart >/dev/null
  done
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    run dockutil --add "$path" --no-restart >/dev/null
  done <<EOF
$wanted
EOF
  run killall Dock || true
  ok "Dock laid out from $(profile_file dock.conf | sed "s#$HOME#~#")"
}

# --- Caps Lock -------------------------------------------------------------

CAPSLOCK_AGENT_LABEL=com.ar4mirez.macos.capslock
CAPSLOCK_SRC=0x700000039

_capslock_dst() {
  case "$1" in
    escape) echo 0x700000029 ;;
    control) echo 0x7000000E0 ;;
    none) echo "" ;;
    *) die "capslock must be none, escape or control (got '$1')" ;;
  esac
}

_capslock_json() { # _capslock_json <dst hex or empty>
  if [ -n "$1" ]; then
    printf '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":%s,"HIDKeyboardModifierMappingDst":%s}]}' "$CAPSLOCK_SRC" "$1"
  else
    printf '{"UserKeyMapping":[]}'
  fi
}

_capslock_agent() { printf '%s\n' "$HOME/Library/LaunchAgents/$CAPSLOCK_AGENT_LABEL.plist"; }

_capslock_agent_plist() { # the LaunchAgent that re-applies the mapping at login
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$CAPSLOCK_AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>hidutil</string>
    <string>property</string>
    <string>--set</string>
    <string>$(_capslock_json "$1")</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF
}

# _capslock_active <dst> — hidutil reports a mapping from Caps Lock to <dst>
# (it prints the codes in decimal or hex, depending on the macOS version).
_capslock_active() {
  local out
  out="$(hidutil property --get UserKeyMapping 2>/dev/null || true)"
  grep -qiE "$((CAPSLOCK_SRC))|${CAPSLOCK_SRC#0x}" <<<"$out" && grep -qiE "$(($1))|${1#0x}" <<<"$out"
}

capslock_state() {
  local mode dst agent
  mode="$(system_setting capslock none)"
  dst="$(_capslock_dst "$mode")"
  agent="$(_capslock_agent)"
  if [ -z "$dst" ]; then
    if [ -f "$agent" ]; then echo "drift remap agent still installed"; else echo ok; fi
    return
  fi
  if [ "$(cat "$agent" 2>/dev/null)" != "$(_capslock_agent_plist "$dst")" ]; then
    echo "drift LaunchAgent missing or outdated"
  elif ! _capslock_active "$dst"; then
    echo "drift mapping not active"
  else
    echo ok
  fi
}

capslock_apply() {
  local mode dst agent
  mode="$(system_setting capslock none)"
  dst="$(_capslock_dst "$mode")"
  agent="$(_capslock_agent)"
  if [ "$(capslock_state)" = ok ]; then
    skip "Caps Lock: $mode (already set)"
    return 0
  fi
  if [ -z "$dst" ]; then
    run rm -f "$agent"
    run hidutil property --set "$(_capslock_json "")" >/dev/null
    ok "Caps Lock remap removed"
    return 0
  fi
  _capslock_agent_plist "$dst" | write_file "$agent"
  run hidutil property --set "$(_capslock_json "$dst")" >/dev/null
  ok "Caps Lock → $mode (re-applied at every login)"
}

# --- Default browser -------------------------------------------------------

# browser_current — bundle id handling http, lowercased. LaunchServices has
# no entry until the user first changes it, which means Safari.
browser_current() {
  local id=""
  if [ -f "$LAUNCHSERVICES_PLIST" ]; then
    id="$(plutil -extract LSHandlers json -o - "$LAUNCHSERVICES_PLIST" 2>/dev/null |
      jq -r '[.[] | select(.LSHandlerURLScheme == "http") | .LSHandlerRoleAll][0] // empty' 2>/dev/null)"
  fi
  printf '%s\n' "${id:-com.apple.safari}" | tr '[:upper:]' '[:lower:]'
}

browser_state() {
  local want
  want="$(system_setting browser none)"
  if [ "$want" = none ] || [ "$(browser_current)" = "$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')" ]; then
    echo ok
  else
    echo "drift default browser is $(browser_current)"
  fi
}

browser_apply() {
  local want
  want="$(system_setting browser none)"
  if [ "$want" = none ]; then
    skip "default browser not managed"
    return 0
  fi
  if [ "$(browser_state)" = ok ]; then
    skip "default browser already $want"
    pending_done browser
    return 0
  fi
  run duti -s "$want" http
  run duti -s "$want" https
  run duti -s "$want" public.html all
  pending_add browser "Confirm the 'change your default web browser' dialog (to $want); re-run 'macos defaults apply' if you dismissed it"
  ok "default browser → $want (macOS asks you to confirm)"
}

# --- Brave policy ----------------------------------------------------------

brave_policy_file() { profile_file brave.mobileconfig; }

# Installed once the profile is approved: macOS then writes the policies as
# managed preferences for this user.
brave_policy_state() {
  [ -n "$(brave_policy_file)" ] || { echo ok; return; }
  if [ -f "$MANAGED_PREFS_DIR/com.brave.Browser.plist" ]; then
    echo ok
  else
    echo "drift Brave policy profile not installed"
  fi
}

brave_policy_apply() {
  local f
  f="$(brave_policy_file)"
  if [ -z "$f" ]; then
    skip "no Brave policy declared"
    return 0
  fi
  if [ "$(brave_policy_state)" = ok ]; then
    skip "Brave policy profile installed"
    pending_done brave-policy
    return 0
  fi
  run open "$f"
  pending_add brave-policy "Approve the 'Brave lean policy' profile in System Settings → General → Device Management, then restart Brave"
  ok "Brave policy profile opened for approval"
}

# --- All -------------------------------------------------------------------

system_apply() {
  dock_apply
  capslock_apply
  browser_apply
  brave_policy_apply
}

# system_check — report drift; returns 1 on any.
system_check() {
  local name state bad=0
  for name in dock capslock browser brave_policy; do
    state="$("${name}_state")"
    if [ "$state" != ok ]; then
      printf '  drift  %s: %s\n' "$name" "${state#drift }"
      bad=1
    fi
  done
  return "$bad"
}
