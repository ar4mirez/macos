# shellcheck shell=bash
# The machine's profile and the profile data in the dotfiles repo.
# bash-3.2-safe. Requires lib/common.sh.

profiles_dir() { printf '%s\n' "$MACOS_DOTFILES/macos/profiles"; }

# A Mac has exactly one main profile, chosen at bootstrap from MAIN_PROFILES.
# Any other profile directory can be stacked on top as an add-on: optional
# ones like gaming, or another main profile (a work Mac adding personal).
# Add-ons are per Mac (MACOS_ADDONS in machine.env), any number, layered
# after the main profile in the same file formats.
# shellcheck disable=SC2034 # read by macos-bootstrap
MAIN_PROFILES="work personal base"

# require_profile — this machine must have been bootstrapped, and its
# add-ons must still exist in the dotfiles repo.
require_profile() {
  local a
  [ -n "${MACOS_PROFILE:-}" ] || die "no profile set for this Mac; run 'macos bootstrap' first"
  [ -d "$(profiles_dir)/base" ] || die "no profile data at $(profiles_dir); is $MACOS_DOTFILES cloned?"
  for a in $(machine_addons); do
    profile_exists "$a" || die "add-on '$a' is enabled on this Mac but $(profiles_dir)/$a does not exist; run 'macos addons remove $a'"
  done
}

# addon_refusal <name> <main profile> — why <name> can't be stacked on a Mac
# whose main profile is <main>, or nothing when it can.
addon_refusal() {
  if [ "$1" = base ]; then
    echo "base is always on"
  elif [ "$1" = "$2" ]; then
    echo "'$1' is this Mac's main profile already"
  fi
}

# available_addons — profiles this Mac can stack, sorted: every profile
# directory except base and its main profile.
available_addons() {
  local d n
  for d in "$(profiles_dir)"/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    [ -z "$(addon_refusal "$n" "${MACOS_PROFILE:-}")" ] && printf '%s\n' "$n"
  done
  return 0
}

# machine_addons — the add-ons enabled on this Mac, one per line.
machine_addons() {
  local a
  for a in ${MACOS_ADDONS:-}; do
    printf '%s\n' "$a"
  done
}

# profiles_label — "work", or "work + gaming" with add-ons.
profiles_label() {
  printf '%s\n' "$MACOS_PROFILE$(machine_addons | sed 's/^/ + /' | tr -d '\n')"
}

# profile_exists <profile>
profile_exists() { [ -d "$(profiles_dir)/$1" ]; }

# active_profiles — base, this machine's profile, then its add-ons: the
# order in which later files override earlier ones.
active_profiles() {
  echo base
  if [ "$MACOS_PROFILE" != base ]; then
    echo "$MACOS_PROFILE"
  fi
  machine_addons
}

# brewfile_declares <Brewfile> <type> <name> — exact entry present?
brewfile_declares() {
  [ -f "$1" ] || return 1
  awk -v t="$2" -v n="$3" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    index(line, t) == 1 {
      rest = substr(line, length(t) + 1)
      if (rest !~ /^[ \t]+"/) next
      sub(/^[ \t]+"/, "", rest)
      if (index(rest, n "\"") == 1) { f = 1 }
    }
    END { exit !f }' "$1"
}

# declared_in <name> [type] — profiles whose Brewfile declares <name>, as
# "profile type" lines.
declared_in() {
  local f p t
  for f in "$(profiles_dir)"/*/Brewfile; do
    [ -f "$f" ] || continue
    p="$(basename "$(dirname "$f")")"
    for t in ${2:-brew cask tap mas}; do
      if brewfile_declares "$f" "$t" "$1"; then
        echo "$p $t"
      fi
    done
  done
}
