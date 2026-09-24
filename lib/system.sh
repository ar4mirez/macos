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

# --- Keyboard shortcuts ----------------------------------------------------

# macOS keeps its own shortcuts (System Settings > Keyboard > Keyboard
# Shortcuts) as a dict of numbered entries in com.apple.symbolichotkeys, which
# defaults.conf cannot express. `hotkeys_off` lists the ids to switch off, e.g.
# 60 (select the previous input source, Ctrl+Space). An id with no entry is
# still at its macOS default, which is on.

# hotkeys_off — the declared ids, one per line; dies on anything else.
hotkeys_off() {
  local id
  for id in $(system_setting hotkeys_off | tr ',' ' '); do
    case "$id" in
      '' | *[!0-9]*) die "hotkeys_off takes numeric shortcut ids (got '$id')" ;;
    esac
    printf '%s\n' "$id"
  done
}

# _hotkey_enabled <id> — the stored enabled flag: false, true or 0/1 (on
# when there is no entry).
_hotkey_enabled() {
  { defaults export com.apple.symbolichotkeys - 2>/dev/null || true; } |
    plutil -extract "AppleSymbolicHotKeys.$1.enabled" raw -o - - 2>/dev/null || echo true
}

# _hotkeys_on — the declared ids that are still on.
_hotkeys_on() {
  local id
  for id in $(hotkeys_off); do
    case "$(_hotkey_enabled "$id")" in
      false | 0) ;;
      *) printf '%s\n' "$id" ;;
    esac
  done
}

hotkeys_state() {
  local on
  hotkeys_off >/dev/null
  on="$(_hotkeys_on | tr '\n' ' ')"
  if [ -z "$on" ]; then
    echo ok
  else
    echo "drift shortcut(s) still on: ${on% }"
  fi
}

hotkeys_apply() {
  local id on
  hotkeys_off >/dev/null # validate before writing anything
  on="$(_hotkeys_on)"
  if [ -z "$on" ]; then
    [ -z "$(hotkeys_off)" ] || skip "keyboard shortcuts $(hotkeys_off | tr '\n' ' ')already off"
    return 0
  fi
  for id in $on; do
    run defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "$id" '<dict><key>enabled</key><false/></dict>'
  done
  run "$ACTIVATE_SETTINGS" -u
  if ! dry_run && [ -n "$(_hotkeys_on)" ]; then
    warn "keyboard shortcut(s) $(_hotkeys_on | tr '\n' ' ')did not turn off"
  else
    ok "keyboard shortcut(s) $(printf '%s' "$on" | tr '\n' ' ') off"
  fi
}

# --- All -------------------------------------------------------------------

system_apply() {
  dock_apply
  capslock_apply
  browser_apply
  hotkeys_apply
  brave_policy_apply
}

# system_check — report drift; returns 1 on any.
system_check() {
  local name state bad=0
  for name in dock capslock browser hotkeys brave_policy; do
    state="$("${name}_state")"
    if [ "$state" != ok ]; then
      printf '  drift  %s: %s\n' "$name" "${state#drift }"
      bad=1
    fi
  done
  return "$bad"
}
