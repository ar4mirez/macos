# shellcheck shell=bash
# Stow-managed dotfiles. Packages are top-level dirs of $MACOS_DOTFILES that
# mirror $HOME; which ones apply comes from the base and profile stow.list.
# bash-3.2-safe. Requires lib/common.sh, lib/run.sh and lib/profile.sh.

IDENTITY_PACKAGES="ssh"

# Files stow never links (on top of its defaults: README*, LICENSE*, .git…).
STOW_IGNORE='\.DS_Store'

# stow_packages — packages for this Mac: base, then profile, de-duplicated.
stow_packages() {
  local p f
  for p in $(active_profiles); do
    f="$(profiles_dir)/$p/stow.list"
    [ -f "$f" ] || continue
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$f" | grep -v '^$' || true
  done | awk '!seen[$0]++'
  # Identity packages (ssh) point at the 1Password agent, so they are linked
  # only once `macos identity` has verified it.
  if [ -f "$MACOS_STATE/identity.verified" ] || [ "${IDENTITY_READY:-}" = 1 ]; then
    for p in $IDENTITY_PACKAGES; do
      if [ -d "$MACOS_DOTFILES/$p" ]; then
        echo "$p"
      fi
    done
  fi
}

# package_files <package> — files a package would link, relative to $HOME.
# Mirrors what stow skips: its built-in ignore list (VCS dirs and files,
# editor backups, top-level README*/LICENSE*/COPYING) plus our .DS_Store.
package_files() {
  (cd "$MACOS_DOTFILES/$1" && find . \
    \( -name .git -o -name CVS -o -name RCS -o -name .svn -o -name _darcs -o -name .hg \) -prune -o \
    \( -type f -o -type l \) \
    ! -name .DS_Store ! -name .gitignore ! -name .gitmodules ! -name .cvsignore ! -name .stow-local-ignore \
    ! -name '*~' ! -name '#*#' ! -name '.#*' ! -name '*,v' \
    ! -path './README*' ! -path './LICENSE*' ! -path './COPYING' -print |
    sed 's#^\./##' | sort)
}

# link_state <package> <relpath> — linked | missing | conflict
link_state() {
  local target="$HOME/$2" want="$MACOS_DOTFILES/$1/$2"
  # Resolving catches a parent directory that is itself a link into the
  # repo (a folded stow): the file is the repo's own, never a conflict.
  if [ -e "$target" ] && [ ! -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$want")" ]; then
    echo linked
  elif [ -L "$target" ]; then
    if [ "$(readlink -f "$target" 2>/dev/null)" = "$(readlink -f "$want")" ]; then
      echo linked
    else
      echo conflict
    fi
  elif [ -e "$target" ]; then
    echo conflict
  else
    echo missing
  fi
}

# dotfiles_require_packages <package>... — every package must exist.
dotfiles_require_packages() {
  local p
  for p in "$@"; do
    [ -d "$MACOS_DOTFILES/$p" ] || die "stow.list names '$p', but $MACOS_DOTFILES/$p does not exist"
  done
}

# dotfiles_backup_conflicts <package>... — move anything in the way (real
# files, or symlinks pointing elsewhere) to $MACOS_STATE/backup/<ts>/,
# keeping the path. Never uses `stow --adopt`, which would pull those files
# into the repo.
dotfiles_backup_conflicts() {
  local p rel dest backup="" moved=0
  for p in "$@"; do
    while IFS= read -r rel; do
      [ "$(link_state "$p" "$rel")" = conflict ] || continue
      if [ -z "$backup" ]; then
        backup="$MACOS_STATE/backup/$(date +%Y%m%d-%H%M%S)"
        run mkdir -p "$MACOS_STATE/backup"
        run chmod 700 "$MACOS_STATE/backup"
      fi
      dest="$backup/$rel"
      run mkdir -p "$(dirname "$dest")"
      run mv "$HOME/$rel" "$dest"
      if dry_run; then
        skip "would move existing ~/$rel to $dest"
      else
        warn "moved existing ~/$rel to $dest"
      fi
      moved=$((moved + 1))
    done <<EOF
$(package_files "$p")
EOF
  done
  if [ "$moved" -gt 0 ] && ! dry_run; then
    say "Backed up $moved file(s) that were in the way."
  fi
}

# dotfiles_restore_backups — put back files the dotfiles once replaced, from
# the oldest engine backup that has them, where nothing is there now.
# Only engine-made backup dirs (<yyyymmdd-hhmmss>) are used, so files you
# moved aside yourself (e.g. a retired key) stay put.
dotfiles_restore_backups() { # dotfiles_restore_backups <paths the packages linked>
  local dir rel restored=0 allowed="$1"
  [ -d "$MACOS_STATE/backup" ] || return 0
  for dir in $(find "$MACOS_STATE/backup" -mindepth 1 -maxdepth 1 -type d | grep -E '/[0-9]{8}-[0-9]{6}$' | sort); do
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      # Only paths a dotfiles package owned; anything else is not ours to put back.
      grep -qxF "$rel" <<<"$allowed" || continue
      if [ -e "$HOME/$rel" ] || [ -L "$HOME/$rel" ]; then
        continue
      fi
      run mkdir -p "$(dirname "$HOME/$rel")"
      run cp -Pp "$dir/$rel" "$HOME/$rel"
      restored=$((restored + 1))
    done <<EOF
$(cd "$dir" && find . \( -type f -o -type l \) | sed 's#^\./##')
EOF
  done
  if [ "$restored" -gt 0 ]; then
    ok "restored $restored file(s) the dotfiles had replaced"
  fi
}

stow_run() { # stow_run <stow flags...> -- <packages...>
  run stow --no-folding --ignore="$STOW_IGNORE" -d "$MACOS_DOTFILES" -t "$HOME" "$@"
}

# dotfiles_all_linked <package>... — every file of every package is linked.
dotfiles_all_linked() {
  local p rel
  for p in "$@"; do
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      [ "$(link_state "$p" "$rel")" = linked ] || return 1
    done <<EOF
$(package_files "$p")
EOF
  done
}

dotfiles_link() {
  local pkgs
  pkgs="$(stow_packages)"
  [ -n "$pkgs" ] || { skip "no stow packages listed for this profile"; return 0; }
  # shellcheck disable=SC2086
  dotfiles_require_packages $pkgs
  if dotfiles_all_linked $pkgs; then
    skip "dotfiles already linked: $(echo $pkgs)"
    return 0
  fi
  # shellcheck disable=SC2086
  dotfiles_backup_conflicts $pkgs
  # shellcheck disable=SC2086
  stow_run --restow $pkgs
  ok "linked: $(echo $pkgs)"
}

dotfiles_unlink() {
  local pkgs
  pkgs="$(stow_packages)"
  [ -n "$pkgs" ] || { skip "no stow packages listed for this profile"; return 0; }
  # shellcheck disable=SC2086
  stow_run --delete $pkgs
  ok "unlinked: $(echo $pkgs)"
}

# dotfiles_status — per-file link state; returns 1 if anything is not linked.
dotfiles_status() {
  local p rel state bad=0
  for p in $(stow_packages); do
    if [ ! -d "$MACOS_DOTFILES/$p" ]; then
      printf '  %-9s %s\n' missing "$p/ (package not in repo)"
      bad=1
      continue
    fi
    while IFS= read -r rel; do
      state="$(link_state "$p" "$rel")"
      printf '  %-9s ~/%s\n' "$state" "$rel"
      [ "$state" = linked ] || bad=1
    done <<EOF
$(package_files "$p")
EOF
  done
  if [ -n "$(git -C "$MACOS_DOTFILES" status --porcelain 2>/dev/null)" ]; then
    printf '  %-9s %s\n' dirty "$MACOS_DOTFILES has uncommitted changes"
  fi
  return "$bad"
}

# mise_install — install the runtimes the linked mise config declares. A gh
# token avoids GitHub API rate limits; it is exported, never put on a
# command line, so it cannot show up in logs or --dry-run output.
mise_install() {
  if ! command -v mise >/dev/null 2>&1; then
    skip "mise not installed"
    return 0
  fi
  if [ -z "$(mise ls --missing 2>/dev/null || echo unknown)" ]; then
    skip "mise runtimes already installed"
    return 0
  fi
  (
    if command -v gh >/dev/null 2>&1 && [ -z "${GITHUB_TOKEN:-}" ]; then
      GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
      export GITHUB_TOKEN
    fi
    run mise install --yes
  )
  ok "mise runtimes installed"
}
