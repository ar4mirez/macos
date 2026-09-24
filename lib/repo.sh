# shellcheck shell=bash
# Git clones authenticated by gh only. The CLT system gitconfig adds the
# osxkeychain helper, which would answer first with a cached (possibly stale)
# token and store every new one; `credential.helper=` clears it.
# bash-3.2-safe. Requires lib/common.sh and lib/run.sh.

GIT_GH_ONLY=(-c credential.helper= -c 'credential.helper=!gh auth git-credential')

# repo_sync <url> <dir> — clone, or fast-forward an existing clone.
repo_sync() {
  local url="$1" dir="$2"
  if [ -d "$dir/.git" ]; then
    if run git "${GIT_GH_ONLY[@]}" -C "$dir" pull --ff-only --quiet; then
      ok "updated $dir"
    else
      warn "could not fast-forward $dir (local changes?); continuing with it as is"
    fi
  elif [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    die "$dir exists but is not a git clone; move it aside and re-run"
  else
    run git "${GIT_GH_ONLY[@]}" clone --quiet "$url" "$dir"
    ok "cloned $url → $dir"
  fi
  repo_harden "$dir"
}

# repo_harden <dir> — persist the gh-only credential setup, and enable the
# repo's hooks (git does not clone hooks).
repo_harden() {
  local dir="$1"
  run git -C "$dir" config --replace-all credential.helper ''
  run git -C "$dir" config --add credential.helper '!gh auth git-credential'
  if [ -d "$dir/.githooks" ] || dry_run; then
    run git -C "$dir" config core.hooksPath .githooks
  fi
}
