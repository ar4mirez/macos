# shellcheck shell=bash
# Brave policy: settings from profiles/*/brave.json plus extensions from
# profiles/*/brave-extensions.conf, delivered as one user configuration
# profile. Chromium applies policy to every browser profile, including ones
# created later, so a declared extension shows up everywhere; an extension
# installed by hand lives in one profile only (see `macos brave adopt`).
# bash-3.2-safe. Requires lib/common.sh, lib/run.sh, lib/profile.sh and
# lib/pending.sh; uses jq and plutil.

BRAVE_DOMAIN=com.brave.Browser
BRAVE_PROFILE_ID=com.ar4mirez.macos.brave
BRAVE_UPDATE_URL=https://clients2.google.com/service/update2/crx

# brave_extension_lines — validated "id|name|mode|pin" for this Mac: base,
# then the profile; a later line for the same id wins.
brave_extension_lines() {
  local p f
  for p in $(active_profiles); do
    f="$(profiles_dir)/$p/brave-extensions.conf"
    [ -f "$f" ] || continue
    awk -F'|' '
      /^[[:space:]]*(#|$)/ { next }
      {
        for (i = 1; i <= 4; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) }
        if ($1 !~ /^[a-p]{32}$/) { printf "%s:%d: not a Chrome Web Store id: %s\n", FILENAME, FNR, $1 > "/dev/stderr"; bad = 1; next }
        if ($3 == "") $3 = "normal"
        if ($3 !~ /^(normal|force)$/) { printf "%s:%d: mode must be normal or force, not %s\n", FILENAME, FNR, $3 > "/dev/stderr"; bad = 1; next }
        if ($4 !~ /^(pin)?$/) { printf "%s:%d: last column must be pin or empty, not %s\n", FILENAME, FNR, $4 > "/dev/stderr"; bad = 1; next }
        print $1 "|" $2 "|" $3 "|" $4
      }
      END { exit bad }' "$f" || die "invalid line(s) in $f"
  done | awk -F'|' '{ if (!($1 in v)) order[++n] = $1; v[$1] = $0 } END { for (i = 1; i <= n; i++) print v[order[i]] }'
}

# brave_policy_json — the full desired policy for this Mac, as JSON: every
# active profile's brave.json merged (later wins), plus ExtensionSettings.
brave_policy_json() {
  local p f files="" ext lines
  for p in $(active_profiles); do
    f="$(profiles_dir)/$p/brave.json"
    if [ -f "$f" ]; then
      jq -e 'type == "object"' "$f" >/dev/null 2>&1 || die "$f is not a JSON object"
      files="$files $f"
    fi
  done
  lines="$(brave_extension_lines)" || exit 1
  ext="$(awk -F'|' 'NF' <<<"$lines" | jq -R -s --arg url "$BRAVE_UPDATE_URL" '
    split("\n") | map(select(length > 0) | split("|")) |
    map({key: .[0], value: ({
      installation_mode: (if .[2] == "force" then "force_installed" else "normal_installed" end),
      update_url: $url
    } + (if .[3] == "pin" then {toolbar_pin: "force_pinned"} else {} end))}) | from_entries')"
  # shellcheck disable=SC2086
  { if [ -n "$files" ]; then jq -s 'reduce .[] as $x ({}; . * $x)' $files; else echo '{}'; fi; } |
    jq -S --argjson ext "$ext" 'if ($ext | length) > 0 then . + {ExtensionSettings: $ext} else . end'
}

# _uuid <seed> — a stable UUID, so re-rendering the same profile does not
# look like a new one to macOS.
_uuid() { md5 -q -s "$1" | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/' | tr 'a-f' 'A-F'; }

# brave_mobileconfig <policy json> <out> — the configuration profile.
brave_mobileconfig() {
  jq -n --argjson policy "$1" --arg id "$BRAVE_PROFILE_ID" --arg domain "$BRAVE_DOMAIN" \
    --arg uuid "$(_uuid "$BRAVE_PROFILE_ID")" --arg puuid "$(_uuid "$BRAVE_PROFILE_ID.policy")" '{
      PayloadType: "Configuration", PayloadVersion: 1, PayloadScope: "User",
      PayloadIdentifier: $id, PayloadUUID: $uuid,
      PayloadDisplayName: "Brave policy (ar4mirez/macos)",
      PayloadDescription: "Brave settings and the extensions installed in every Brave profile, from ~/.dotfiles/macos/profiles/*/brave.json and brave-extensions.conf.",
      PayloadRemovalDisallowed: false,
      PayloadContent: [ ({
        PayloadType: $domain, PayloadVersion: 1,
        PayloadIdentifier: ($id + ".policy"), PayloadUUID: $puuid,
        PayloadDisplayName: "Brave policy"
      } + $policy) ]
    }' | plutil -convert xml1 -o "$2" - || die "could not build the Brave configuration profile"
}

# brave_policy_active — the policy macOS applied (from the approved
# profile), as normalized JSON; empty when none is installed.
brave_policy_active() {
  local f="$MANAGED_PREFS_DIR/$BRAVE_DOMAIN.plist"
  [ -f "$f" ] || return 0
  plutil -convert json -o - "$f" 2>/dev/null |
    jq -S 'with_entries(select(.key | (startswith("Payload") or startswith("_")) | not))' 2>/dev/null
}

# brave_policy_declared — true when any active profile declares a policy.
brave_policy_declared() {
  local p
  for p in $(active_profiles); do
    if [ -f "$(profiles_dir)/$p/brave.json" ] || [ -f "$(profiles_dir)/$p/brave-extensions.conf" ]; then
      return 0
    fi
  done
  return 1
}

brave_policy_state() {
  local want have
  brave_policy_declared || { echo ok; return; }
  want="$(brave_policy_json)" || exit 1
  have="$(brave_policy_active)"
  if [ -z "$have" ]; then
    echo "drift Brave policy profile not installed"
  elif [ "$(jq -S . <<<"$want")" != "$have" ]; then
    echo "drift Brave policy differs from brave.json / brave-extensions.conf"
  else
    echo ok
  fi
}

brave_policy_apply() {
  local out state
  if ! brave_policy_declared; then
    skip "no Brave policy declared"
    return 0
  fi
  state="$(brave_policy_state)" || exit 1
  if [ "$state" = ok ]; then
    skip "Brave policy up to date ($(brave_extension_lines | awk 'NF' | wc -l | tr -d ' ') extension(s) in every profile)"
    pending_done brave-policy
    return 0
  fi
  out="$MACOS_STATE/brave.mobileconfig"
  if dry_run; then
    out="$(mktemp "${TMPDIR:-/tmp}/macos-brave.XXXXXX")"
    on_exit "rm -f '$out'"
  fi
  brave_mobileconfig "$(brave_policy_json)" "$out"
  run open "$out"
  pending_add brave-policy "Approve the 'Brave policy (ar4mirez/macos)' profile in System Settings → General → Device Management (it replaces the previous one), then restart Brave"
  ok "Brave policy profile opened for approval (${state#drift })"
}

# --- extensions installed by hand -------------------------------------------

: "${BRAVE_SUPPORT_DIR:=$HOME/Library/Application Support/BraveSoftware/Brave-Browser}"

# brave_installed_extensions — "id|name|profile dir" for Web Store extensions
# installed by hand in any Brave profile (location 1 = user install).
brave_installed_extensions() {
  local prof pref
  [ -d "$BRAVE_SUPPORT_DIR" ] || return 0
  for prof in "$BRAVE_SUPPORT_DIR"/Default "$BRAVE_SUPPORT_DIR"/Profile\ *; do
    [ -d "$prof" ] || continue
    for pref in "$prof/Secure Preferences" "$prof/Preferences"; do
      [ -f "$pref" ] || continue
      jq -r --arg p "$(basename "$prof")" '
        (.extensions.settings // {}) | to_entries[]
        | select(.value.location == 1 and (.value.from_webstore // true))
        | "\(.key)|\(.value.manifest.name // .key)|\($p)"' "$pref" 2>/dev/null || true
    done
  done | awk -F'|' '!seen[$1]++'
}

# brave_extension_name <id> <profile dir name> — its display name, from the
# installed manifest (resolving __MSG_…__ through _locales), else the id.
brave_extension_name() {
  local dir m name key loc
  dir="$(ls -d "$BRAVE_SUPPORT_DIR/$2/Extensions/$1"/*/ 2>/dev/null | tail -n 1)"
  m="${dir}manifest.json"
  [ -f "$m" ] || { echo "$1"; return; }
  name="$(jq -r '.name // empty' "$m" 2>/dev/null)"
  case "$name" in
    __MSG_*__)
      key="${name#__MSG_}"; key="${key%__}"
      loc="$(jq -r '.default_locale // "en"' "$m")"
      name="$(jq -r --arg k "$key" 'to_entries[] | select((.key | ascii_downcase) == ($k | ascii_downcase)) | .value.message' \
        "${dir}_locales/$loc/messages.json" 2>/dev/null | head -n 1)"
      ;;
  esac
  echo "${name:-$1}"
}
