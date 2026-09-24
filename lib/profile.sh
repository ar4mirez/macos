# shellcheck shell=bash
# The machine's profile and the profile data in the dotfiles repo.
# bash-3.2-safe. Requires lib/common.sh.

profiles_dir() { printf '%s\n' "$MACOS_DOTFILES/macos/profiles"; }

# A Mac has exactly one main profile. Every other directory under
# profiles/ is an add-on: optional, any number per Mac (MACOS_ADDONS in
# machine.env), layered after the main profile in the same file formats.
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

# is_main_profile <name>
is_main_profile() {
  case " $MAIN_PROFILES " in *" $1 "*) return 0 ;; esac
  return 1
}

# available_addons — add-on names in the dotfiles repo, sorted.
available_addons() {
  local d n
  for d in "$(profiles_dir)"/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    is_main_profile "$n" || printf '%s\n' "$n"
  done
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
