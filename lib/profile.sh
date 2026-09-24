# shellcheck shell=bash
# The machine's profile and the profile data in the dotfiles repo.
# bash-3.2-safe. Requires lib/common.sh.

profiles_dir() { printf '%s\n' "$MACOS_DOTFILES/macos/profiles"; }

# require_profile — this machine must have been bootstrapped.
require_profile() {
  [ -n "${MACOS_PROFILE:-}" ] || die "no profile set for this Mac; run 'macos bootstrap' first"
  [ -d "$(profiles_dir)/base" ] || die "no profile data at $(profiles_dir); is $MACOS_DOTFILES cloned?"
}

# profile_exists <profile>
profile_exists() { [ -d "$(profiles_dir)/$1" ]; }

# active_profiles — base, plus this machine's profile.
active_profiles() {
  echo base
  if [ "$MACOS_PROFILE" != base ]; then
    echo "$MACOS_PROFILE"
  fi
}

# brewfile_declares <Brewfile> <type> <name> — exact entry present?
brewfile_declares() {
  [ -f "$1" ] || return 1
  awk -v t="$2" -v n="\"$3\"" '$1 == t && ($2 == n || $2 == n ",") { f = 1 } END { exit !f }' "$1"
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
