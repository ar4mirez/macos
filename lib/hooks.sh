# shellcheck shell=bash
# Hooks: your scripts, run at engine events (Omarchy's ~/.config/omarchy/hooks).
#
#   post-apply    at the end of a successful `macos apply`
#   post-update   at the end of `macos update`
#   login         at every login, each in the background (Omarchy's autostart
#                 and post-boot): start apps, daemons, your own scripts
#
# Hooks live in <event>.d directories, run in this order: each active
# profile's macos/profiles/<p>/hooks/ in the dotfiles repo (base, the
# profile, its add-ons), then this Mac's own ~/.config/macos/hooks/, which is
# never committed. Within a directory, files run in name order; *.sample
# files are skipped. An executable file runs directly (any shebang), any
# other with bash. A failing hook is reported and never stops the engine.
# bash-3.2-safe. Requires lib/common.sh, lib/run.sh and lib/profile.sh.

HOOK_EVENTS="post-apply post-update login"
LOGIN_AGENT_LABEL=com.ar4mirez.macos.login

hooks_local_dir() { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/macos/hooks"; }

# hook_event_valid <event>
hook_event_valid() {
  case " $HOOK_EVENTS " in *" $1 "*) return 0 ;; esac
  return 1
}

# hook_files <event> — the hooks to run, in order, one path per line.
hook_files() {
  local p d f
  {
    for p in $(active_profiles); do
      printf '%s\n' "$(profiles_dir)/$p/hooks/$1.d"
    done
    printf '%s\n' "$(hooks_local_dir)/$1.d"
  } | while IFS= read -r d; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      case "$f" in *.sample) continue ;; esac
      printf '%s\n' "$f"
    done
  done
}

# _hook_exec <file> [args...] — run one hook the way its file asks for.
_hook_exec() {
  local f="$1"
  shift
  if [ -x "$f" ]; then "$f" "$@"; else bash "$f" "$@"; fi
}

# hooks_run <event> [args...] — run the event's hooks; `login` hooks start in
# the background, detached, so a long-running one doesn't hold up the rest.
hooks_run() {
  local event="$1" f name
  shift
  hook_event_valid "$event" || die "unknown hook event '$event' (one of: $HOOK_EVENTS)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    name="${f#"$MACOS_DOTFILES"/macos/profiles/}"
    name="${name#"$(hooks_local_dir)"/}"
    if dry_run; then
      say "would run hook: $name"
    elif [ "$event" = login ]; then
      (MACOS_HOOK_EVENT="$event" _hook_exec "$f" "$@" </dev/null &)
      ok "started hook: $name"
    elif MACOS_HOOK_EVENT="$event" _hook_exec "$f" "$@"; then
      ok "hook: $name"
    else
      warn "hook failed: $name (exit $?); carrying on"
    fi
  done <<EOF
$(hook_files "$event")
EOF
}

# --- Login agent ----------------------------------------------------------------
# One LaunchAgent runs `macos hook run login` at every login, as long as any
# login hook exists. It isn't started now: a new agent runs at the next login.

login_agent() { printf '%s\n' "$HOME/Library/LaunchAgents/$LOGIN_AGENT_LABEL.plist"; }

_login_agent_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LOGIN_AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HOME/.local/bin/macos</string>
    <string>hook</string>
    <string>run</string>
    <string>login</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$HOME/.local/bin:$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$MACOS_STATE/logs/login-hooks.log</string>
  <key>StandardErrorPath</key>
  <string>$MACOS_STATE/logs/login-hooks.log</string>
</dict>
</plist>
EOF
}

login_agent_state() {
  local agent
  agent="$(login_agent)"
  if [ -z "$(hook_files login)" ]; then
    if [ -f "$agent" ]; then echo "drift login agent installed but no login hooks"; else echo ok; fi
  elif [ "$(cat "$agent" 2>/dev/null)" != "$(_login_agent_plist)" ]; then
    echo "drift login agent missing or outdated"
  else
    echo ok
  fi
}

login_agent_apply() {
  local agent n
  agent="$(login_agent)"
  n="$(hook_files login | grep -c . || true)"
  if [ "$(login_agent_state)" = ok ]; then
    if [ "$n" -gt 0 ]; then skip "login hooks: $n (run at login)"; fi
    return 0
  fi
  if [ "$n" -eq 0 ]; then
    run rm -f "$agent"
    ok "login agent removed (no login hooks)"
    return 0
  fi
  run mkdir -p "$MACOS_STATE/logs"
  _login_agent_plist | write_file "$agent"
  ok "login hooks: $n, run at every login from the next one"
}
