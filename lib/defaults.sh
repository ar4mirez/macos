# shellcheck shell=bash
# Declarative macOS defaults from profiles/*/defaults.conf:
#
#   domain | key | type | value
#
# domain is a defaults domain, -g, or @currentHost:<domain>. A setting only
# counts as applied when both the stored type and value match; every write
# is read back. bash-3.2-safe. Requires lib/common.sh, lib/run.sh and
# lib/profile.sh.

# defaults_lines — "domain|key|type|value" for this Mac: base first, then the
# profile; a later declaration of the same domain+key wins.
defaults_lines() {
  local p f
  for p in $(active_profiles); do
    f="$(profiles_dir)/$p/defaults.conf"
    [ -f "$f" ] || continue
    awk -F'|' '
      /^[[:space:]]*(#|$)/ { next }
      NF < 4 { printf "%s:%d: expected domain | key | type | value\n", FILENAME, FNR > "/dev/stderr"; bad = 1; next }
      {
        for (i = 1; i <= 4; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) }
        if ($3 !~ /^(bool|int|float|string)$/) {
          printf "%s:%d: unknown type %s (bool, int, float or string)\n", FILENAME, FNR, $3 > "/dev/stderr"; bad = 1; next
        }
        if ($3 == "bool" && $4 !~ /^(true|false|yes|no|TRUE|FALSE|YES|NO|1|0)$/) {
          printf "%s:%d: not a bool: %s\n", FILENAME, FNR, $4 > "/dev/stderr"; bad = 1; next
        }
        if ($3 == "int" && $4 !~ /^-?(0|[1-9][0-9]*)$/) {
          printf "%s:%d: not an int: %s\n", FILENAME, FNR, $4 > "/dev/stderr"; bad = 1; next
        }
        if ($3 == "float" && $4 !~ /^-?[0-9]*\.?[0-9]+$/) {
          printf "%s:%d: not a float: %s\n", FILENAME, FNR, $4 > "/dev/stderr"; bad = 1; next
        }
        print $1 "|" $2 "|" $3 "|" $4
      }
      END { exit bad }' "$f" || die "invalid line(s) in $f"
  done | awk -F'|' '{ k = $1 "|" $2; if (!(k in v)) order[++n] = k; v[k] = $0 }
                    END { for (i = 1; i <= n; i++) print v[order[i]] }'
}

# _dflags <domain> — sets _DHOST (-currentHost or empty) and _DDOM.
_dflags() {
  case "$1" in
    @currentHost:*) _DHOST=-currentHost; _DDOM="${1#@currentHost:}" ;;
    *) _DHOST=""; _DDOM="$1" ;;
  esac
}

# _dnorm <type> <value> — the form `defaults read` prints for that value.
_dnorm() {
  case "$1" in
    bool)
      case "$2" in
        true | TRUE | yes | YES | 1) echo 1 ;;
        false | FALSE | no | NO | 0) echo 0 ;;
        *) die "not a bool: '$2'" ;;
      esac
      ;;
    int | float) echo "$2" ;; # written exactly as declared
    string)
      case "$2" in
        "~") echo "$HOME" ;;
        \~/*) echo "$HOME/${2#\~/}" ;; # a literal "~/" prefix in the declared value
        *) echo "$2" ;;
      esac
      ;;
    *) die "unknown defaults type '$1' (bool, int, float or string)" ;;
  esac
}

# _dtypename <type> — what `defaults read-type` reports.
_dtypename() {
  case "$1" in
    bool) echo boolean ;;
    int) echo integer ;;
    *) echo "$1" ;;
  esac
}

# defaults_state <domain> <key> <type> <value> — "ok", or "drift <current>".
defaults_state() {
  local want cur curtype
  _dflags "$1"
  want="$(_dnorm "$3" "$4")"
  # shellcheck disable=SC2086
  curtype="$(defaults $_DHOST read-type "$_DDOM" "$2" 2>/dev/null | sed -n 's/^Type is //p')"
  # shellcheck disable=SC2086
  cur="$(defaults $_DHOST read "$_DDOM" "$2" 2>/dev/null)" || cur="(unset)"
  # Floats compare as numbers (0 == 0.000), everything else as text.
  if [ "$3" = float ] && [ "$cur" != "(unset)" ] && awk -v a="$cur" -v b="$want" 'BEGIN { exit !(a + 0 == b + 0) }'; then
    cur="$want"
  fi
  if [ "$curtype" = "$(_dtypename "$3")" ] && [ "$cur" = "$want" ]; then
    echo ok
  elif [ -n "$curtype" ] && [ "$curtype" != "$(_dtypename "$3")" ]; then
    echo "drift $cur ($curtype)"
  else
    echo "drift $cur"
  fi
}

# Processes that must re-read their preferences, by domain.
_defaults_restart_for() {
  case "$1" in
    com.apple.dock) echo Dock ;;
    com.apple.finder) echo Finder ;;
    com.apple.screencapture) echo SystemUIServer ;;
    *) echo settings ;;
  esac
}

# defaults_apply — write every drifted setting and verify it. Prints nothing
# to stdout; sets DEFAULTS_CHANGED to the number of settings written.
defaults_apply() {
  local dom key type val want state restart="" r lines
  DEFAULTS_CHANGED=0
  # Captured first: a failure inside a heredoc substitution would be ignored.
  lines="$(defaults_lines)" || exit 1
  while IFS='|' read -r dom key type val; do
    [ -n "$dom" ] || continue
    state="$(defaults_state "$dom" "$key" "$type" "$val")"
    if [ "$state" = ok ]; then
      continue
    fi
    _dflags "$dom"
    want="$(_dnorm "$type" "$val")"
    if [ "$_DDOM" = com.apple.screencapture ] && [ "$key" = location ]; then
      run mkdir -p "$want"
    fi
    if [ "$type" = bool ]; then
      [ "$want" = 1 ] && val=true || val=false
    else
      val="$want"
    fi
    # shellcheck disable=SC2086
    run defaults $_DHOST write "$_DDOM" "$key" "-$type" "$val"
    DEFAULTS_CHANGED=$((DEFAULTS_CHANGED + 1))
    if ! dry_run && [ "$(defaults_state "$dom" "$key" "$type" "$val")" != ok ]; then
      warn "$dom $key did not take (macOS may ignore or override this key)"
    else
      ok "$dom $key → $val (was ${state#drift })"
    fi
    r="$(_defaults_restart_for "$_DDOM")"
    case " $restart " in *" $r "*) ;; *) restart="$restart $r" ;; esac
  done <<EOF
$lines
EOF

  if [ "$DEFAULTS_CHANGED" -eq 0 ]; then
    skip "all declared defaults already set"
    return 0
  fi
  for r in $restart; do
    if [ "$r" = settings ]; then
      run "$ACTIVATE_SETTINGS" -u
    else
      run killall "$r" || true
    fi
  done
  say "Some settings (keyboard, trackpad) fully apply only after logging out and back in."
}

# defaults_check — report drift without writing; returns 1 on any drift.
defaults_check() {
  local dom key type val state bad=0 lines
  lines="$(defaults_lines)" || exit 1
  while IFS='|' read -r dom key type val; do
    [ -n "$dom" ] || continue
    state="$(defaults_state "$dom" "$key" "$type" "$val")"
    if [ "$state" != ok ]; then
      printf '  drift  %s %s: %s → %s\n' "$dom" "$key" "${state#drift }" "$(_dnorm "$type" "$val")"
      bad=1
    fi
  done <<EOF
$lines
EOF
  return "$bad"
}
