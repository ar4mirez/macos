# shellcheck shell=bash
# GitHub CLI authentication. bash-3.2-safe.
# Requires lib/common.sh, lib/run.sh and lib/prompt.sh.

# Beyond gh's defaults (repo, read:org, gist): uploading SSH auth and signing
# keys during `macos identity`.
GH_EXTRA_SCOPES="admin:public_key admin:ssh_signing_key"

gh_scopes() {
  gh auth status -h github.com 2>&1 | sed -n "s/.*Token scopes: //p" | tr -d "'," | head -n 1
}

gh_ensure_auth() {
  local missing="" s scopes
  if ! gh auth status -h github.com >/dev/null 2>&1; then
    [ "$MACOS_YES" = 1 ] && die "gh is not logged in; run 'gh auth login' (or set GH_TOKEN) and re-run"
    say "Log in to GitHub (a browser window will open)."
    interactive gh auth login -h github.com -p https -w -s "$(printf '%s' "$GH_EXTRA_SCOPES" | tr ' ' ',')"
    ok "gh logged in"
  else
    scopes=" $(gh_scopes) "
    for s in $GH_EXTRA_SCOPES; do
      case "$scopes" in *" $s "*) ;; *) missing="$missing,$s" ;; esac
    done
    if [ -n "$missing" ]; then
      [ "$MACOS_YES" = 1 ] && die "gh token lacks scopes ${missing#,}; run 'gh auth refresh -h github.com -s ${missing#,}'"
      say "gh needs extra scopes: ${missing#,}"
      interactive gh auth refresh -h github.com -s "${missing#,}"
      ok "gh scopes refreshed"
    else
      skip "gh already logged in with the needed scopes"
    fi
  fi

  # SSH works only once `macos identity` has verified the 1Password agent.
  if [ ! -f "$MACOS_STATE/identity.verified" ] && [ "$(gh config get git_protocol -h github.com 2>/dev/null)" != https ]; then
    run gh config set git_protocol https -h github.com
    ok "gh git protocol → https (until the 1Password SSH agent is verified)"
  fi
}
