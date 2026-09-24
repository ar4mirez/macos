# shellcheck shell=bash
# Git identities, SSH through the 1Password agent, and commit signing, from
# $MACOS_DOTFILES/macos/orgs.conf:
#
#   org | directory | email | github_user | signing_key | github_owners
#
# `default` is the identity used everywhere else (directory is ignored).
# signing_key is a public key, or `agent:<title>` to use the 1Password key
# with that item title (1Password puts the title in the key's comment).
# github_owners (optional, space-separated GitHub orgs/users) also selects
# the identity by remote URL, not only by directory. Generated files are
# machine-local and never committed:
#
#   ~/.config/git/identity.gitconfig    included last by the stowed git config
#   ~/.config/git/identity.d/<org>.gitconfig
#   ~/.config/git/allowed_signers       for verifying signatures locally
#   ~/.ssh/config.d/macos-identity      github.com host + per-account aliases
#   ~/.ssh/macos-<org>.pub              public keys (the private halves stay in 1Password)
#
# bash-3.2-safe. Requires lib/common.sh, lib/run.sh, lib/prompt.sh,
# lib/pending.sh, lib/profile.sh and lib/dotfiles.sh.

IDENTITY_VERIFIED="$MACOS_STATE/identity.verified"
# The agent's public keys (`ssh-add -L`) as of the last run it answered:
# lets a verified Mac keep signing, and apply orgs.conf changes, while
# 1Password is closed. Public keys only; nothing secret.
IDENTITY_KEY_CACHE="$MACOS_STATE/identity.agent-keys"
AGENT_LINK="$HOME/.1password/agent.sock"
GIT_DIR_CFG="$HOME/.config/git"

orgs_file() { printf '%s\n' "$MACOS_DOTFILES/macos/orgs.conf"; }

# orgs_lines — validated "org|dir|email|user|key|owners" lines.
orgs_lines() {
  local f
  f="$(orgs_file)"
  [ -f "$f" ] || return 0
  awk -F'|' '
    /^[[:space:]]*(#|$)/ { next }
    {
      for (i = 1; i <= 6; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) }
      if (NF < 5 || $1 == "" || $3 == "") {
        printf "%s:%d: expected org | directory | email | github_user | signing_key [| github_owners]\n", FILENAME, FNR > "/dev/stderr"; bad = 1; next
      }
      if ($1 != "default" && $2 == "") { printf "%s:%d: org %s needs a directory\n", FILENAME, FNR, $1 > "/dev/stderr"; bad = 1 }
      if ($1 in seen) { printf "%s:%d: org %s declared twice\n", FILENAME, FNR, $1 > "/dev/stderr"; bad = 1 }
      seen[$1] = 1; n++
      if ($1 == "default") defaults++
      print $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6
    }
    END {
      if (n > 0 && defaults != 1) { print "orgs.conf needs exactly one `default` identity" > "/dev/stderr"; bad = 1 }
      exit bad
    }' "$f"
}

# key_material <public key> — "type base64", dropping any comment.
key_material() { printf '%s\n' "$1" | awk '{ print $1, $2 }'; }

# --- 1Password agent -------------------------------------------------------

agent_ready() { SSH_AUTH_SOCK="$OP_AGENT_SOCK" ssh-add -l >/dev/null 2>&1; }

agent_keys() { SSH_AUTH_SOCK="$OP_AGENT_SOCK" ssh-add -L 2>/dev/null | awk '{ print $1, $2 }'; }

# orgs_resolve <lines> <agent keys with comments> — replace `agent:<title>`
# keys with the matching agent key; unmatched ones become empty (unsigned).
orgs_resolve() {
  local org dir email user key owners title found
  while IFS='|' read -r org dir email user key owners; do
    [ -n "$org" ] || continue
    case "$key" in
      agent:*)
        title="${key#agent:}"
        found="$(printf '%s\n' "$2" | awk -v t="$title" '{ c = $0; sub(/^[^ ]+ [^ ]+ ?/, "", c) } c == t { print $1, $2; exit }')"
        if [ -z "$found" ] && [ -n "$2" ]; then
          warn "$org: no key titled '$title' in the 1Password agent"
        fi
        key="$found"
        ;;
    esac
    printf '%s|%s|%s|%s|%s|%s\n' "$org" "$dir" "$email" "$user" "$key" "$owners"
  done <<EOF
$1
EOF
}

# agent_blocked — macOS privacy protection is denying access to 1Password's
# data folder (first access from a terminal needs your OK in a prompt).
# (ls fails either way; `|| true` keeps pipefail from masking grep's match.)
# shellcheck disable=SC2010 # matching ls's error message, not file names
agent_blocked() { { ls "$(dirname "$OP_AGENT_SOCK")" 2>&1 || true; } | grep -q 'Operation not permitted'; }

# identity_wait_agent — true once the agent answers with at least one key.
# Interactive runs open 1Password and let you retry; otherwise it becomes a
# pending step.
identity_wait_agent() {
  if agent_ready; then
    pending_done 1password
    return 0
  fi
  # Already set up once: 1Password being closed right now is normal.
  if [ -f "$IDENTITY_VERIFIED" ] && { [ "$MACOS_YES" = 1 ] || dry_run; }; then
    return 1
  fi
  pending_add 1password "Sign in to 1Password; in Settings → Developer turn on 'Use the SSH agent' and 'Integrate with 1Password CLI'; then run 'macos identity'"
  if agent_blocked; then
    warn "macOS is blocking access to 1Password's data folder; run 'macos identity' from your own terminal and allow access when macOS asks"
  fi
  if [ "$MACOS_YES" = 1 ] || dry_run; then
    warn "1Password SSH agent is not answering yet; signing and ssh config wait for it"
    return 1
  fi
  run open -a 1Password
  while :; do
    say "In 1Password: sign in, then Settings → Developer → 'Use the SSH agent' (add or import your SSH keys)."
    confirm "Is the 1Password SSH agent on? (no = finish later with 'macos identity')" || return 1
    if agent_ready; then
      pending_done 1password
      ok "1Password SSH agent is answering"
      return 0
    fi
    warn "still no keys from the agent at $OP_AGENT_SOCK"
  done
}

identity_link_agent() {
  if [ "$(readlink "$AGENT_LINK" 2>/dev/null)" = "$OP_AGENT_SOCK" ]; then
    skip "agent socket link already in place (~/.1password/agent.sock)"
    return 0
  fi
  run mkdir -p "$(dirname "$AGENT_LINK")"
  run ln -sfn "$OP_AGENT_SOCK" "$AGENT_LINK"
  ok "linked ~/.1password/agent.sock → 1Password's agent"
}

# --- rendering -------------------------------------------------------------

# _write_if_changed <path> — write stdin unless the file already matches.
_write_if_changed() {
  local path="$1" content
  content="$(cat)"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
    return 1
  fi
  printf '%s\n' "$content" | write_file "$path"
}

# _signing_enabled <key> <agent keys> — sign only with a key the agent holds.
_signing_enabled() {
  [ -n "$1" ] && grep -qxF "$(key_material "$1")" <<<"$2"
}

identity_render() { # identity_render <agent keys, or empty when not verified>
  local lines="$1" keys="$2" org dir email user key owners sign changed=0
  local default_user="" main defblock="" includes="" aliases="" signers="" owner d

  default_user="$(printf '%s\n' "$lines" | awk -F'|' '$1 == "default" { print $4 }')"

  main="# Generated by \`macos identity\` from $(orgs_file | sed "s#$HOME#~#"). Do not edit."
  while IFS='|' read -r org dir email user key owners; do
    [ -n "$org" ] || continue
    sign=false
    if _signing_enabled "$key" "$keys"; then sign=true; fi
    if [ -n "$key" ] && [ "$sign" = false ] && [ -n "$keys" ]; then
      warn "$org: signing key is not in the 1Password agent; commits for $org stay unsigned"
    fi

    if [ -n "$key" ]; then
      key_material "$key" | _write_if_changed "$HOME/.ssh/macos-$org.pub" && changed=1
      signers="$signers$email namespaces=\"git\" $(key_material "$key")
"
    fi

    # The default identity goes first, whatever its line in orgs.conf, so
    # the includeIf blocks after it always win inside their scope.
    if [ "$org" = default ]; then
      defblock="
[user]
	email = $email"
      [ -n "$key" ] && defblock="$defblock
	signingkey = $(key_material "$key")"
      defblock="$defblock
[commit]
	gpgsign = $sign
[tag]
	gpgsign = $sign"
      continue
    fi

    {
      printf '# Generated by `macos identity` for %s. Do not edit.\n[user]\n\temail = %s\n' "$org" "$email"
      [ -n "$key" ] && printf '\tsigningkey = %s\n' "$(key_material "$key")"
      printf '[commit]\n\tgpgsign = %s\n[tag]\n\tgpgsign = %s\n' "$sign" "$sign"
      # A different GitHub account needs its own SSH host alias and key; the
      # rewrite exists only when the alias does (same condition below).
      if [ -n "$user" ] && [ -n "$default_user" ] && [ "$user" != "$default_user" ] && [ -n "$key" ]; then
        printf '[url "git@github.com-%s:"]\n\tinsteadOf = git@github.com:\n' "$org"
      fi
    } | _write_if_changed "$GIT_DIR_CFG/identity.d/$org.gitconfig" && changed=1

    d="${dir%/}/"
    includes="$includes
[includeIf \"gitdir:$d\"]
	path = $GIT_DIR_CFG/identity.d/$org.gitconfig"
    for owner in $owners; do
      includes="$includes
[includeIf \"hasconfig:remote.*.url:git@github.com:$owner/**\"]
	path = $GIT_DIR_CFG/identity.d/$org.gitconfig
[includeIf \"hasconfig:remote.*.url:https://github.com/$owner/**\"]
	path = $GIT_DIR_CFG/identity.d/$org.gitconfig"
    done

    if [ -n "$user" ] && [ "$user" != "$default_user" ] && [ -n "$key" ]; then
      aliases="$aliases
Host github.com-$org
  HostName github.com
  User git
  IdentityFile ~/.ssh/macos-$org.pub
  IdentitiesOnly yes"
    fi
  done <<EOF
$lines
EOF

  main="$main$defblock$includes"
  if [ -n "$keys" ]; then
    main="$main
[gpg]
	format = ssh
[gpg \"ssh\"]
	program = $OP_SSH_SIGN
	allowedSignersFile = $GIT_DIR_CFG/allowed_signers"
  fi
  printf '%s\n' "$main" | _write_if_changed "$GIT_DIR_CFG/identity.gitconfig" && changed=1
  printf '%s' "$signers" | _write_if_changed "$GIT_DIR_CFG/allowed_signers" && changed=1

  # ssh: pin github.com to the default key (1Password may hold more than the
  # 6 keys sshd tries before refusing), plus aliases for other accounts.
  key="$(printf '%s\n' "$lines" | awk -F'|' '$1 == "default" { print $5 }')"
  {
    printf '# Generated by `macos identity`. Do not edit.\n'
    if [ -n "$key" ]; then
      printf 'Host github.com\n  User git\n  IdentityFile ~/.ssh/macos-default.pub\n  IdentitiesOnly yes\n'
    fi
    printf '%s\n' "$aliases" | sed '/^$/d'
  } | _write_if_changed "$HOME/.ssh/config.d/macos-identity" && changed=1
  if [ -d "$HOME/.ssh/config.d" ] && [ "$(stat -f %Lp "$HOME/.ssh/config.d")" != 700 ]; then
    run chmod 700 "$HOME/.ssh/config.d"
  fi

  if [ "$changed" = 1 ]; then
    ok "git identities rendered from orgs.conf"
  else
    skip "git identities already up to date"
  fi
}

# --- GitHub ----------------------------------------------------------------

# identity_upload_keys <lines> — make sure GitHub has each key, for auth and
# signing, on the account gh is logged in as. Other accounts become pending.
# _gh_keys <api path> — "type base64" per key, or fail when GitHub can't be asked.
_gh_keys() {
  local out
  out="$(gh api --paginate "$1" -q '.[].key' 2>/dev/null)" || return 1
  awk '{ print $1, $2 }' <<<"$out"
}

# _gh_whoami — the gh login, or empty; explains why when empty.
_gh_whoami() {
  local me
  me="$(gh api user -q .login 2>/dev/null || true)"
  if [ -z "$me" ]; then
    if gh auth status -h github.com >/dev/null 2>&1; then
      warn "couldn't reach GitHub; skipping key checks and uploads"
    else
      warn "gh is not logged in; skipping key checks and uploads"
    fi
  fi
  printf '%s' "$me"
}

# identity_upload_keys <lines> — make sure GitHub has each key, for auth and
# signing, on the account gh is logged in as. Keys for other accounts can't
# be uploaded from here: they stay a pending step until GitHub shows them.
identity_upload_keys() {
  local lines="$1" org dir email user key owners me have_auth have_sign tmp mat
  me="$(_gh_whoami)"
  [ -n "$me" ] || return 0
  if ! have_auth="$(_gh_keys user/keys)" || ! have_sign="$(_gh_keys user/ssh_signing_keys)"; then
    warn "couldn't list your GitHub keys (token lacks admin:public_key / admin:ssh_signing_key?); skipping uploads"
    return 0
  fi
  while IFS='|' read -r org dir email user key owners; do
    [ -n "$org" ] && [ -n "$key" ] || continue
    user="${user:-$me}"
    mat="$(key_material "$key")"
    if [ "$user" != "$me" ]; then
      identity_other_account "$org" "$user" "$mat"
      continue
    fi
    tmp="$MACOS_STATE/tmp-$org.pub"
    if ! grep -qxF "$mat" <<<"$have_auth"; then
      printf '%s\n' "$mat" | write_file "$tmp"
      if run gh ssh-key add "$tmp" --type authentication --title "$org ($(scutil --get ComputerName 2>/dev/null || hostname))"; then
        ok "uploaded $org key to GitHub for authentication"
      else
        warn "could not upload the $org key for authentication; add it at github.com/settings/keys"
      fi
    fi
    if ! grep -qxF "$mat" <<<"$have_sign"; then
      printf '%s\n' "$mat" | write_file "$tmp"
      if run gh ssh-key add "$tmp" --type signing --title "$org signing"; then
        ok "uploaded $org key to GitHub for signing"
      else
        warn "could not upload the $org key for signing; add it at github.com/settings/keys"
      fi
    fi
    if [ -e "$tmp" ]; then
      run rm -f "$tmp"
    fi
  done <<EOF
$lines
EOF
}

# identity_other_account <org> <github user> <key material> — pending until
# GitHub's public key lists for that user show the key (both kinds).
identity_other_account() {
  local auth sign
  auth="$(_gh_keys "users/$2/keys" || true)"
  sign="$(_gh_keys "users/$2/ssh_signing_keys" || true)"
  if grep -qxF "$3" <<<"$auth" && grep -qxF "$3" <<<"$sign"; then
    pending_done "github-keys-$1"
  else
    pending_add "github-keys-$1" "Add the $1 SSH key to GitHub account $2 as both an authentication and a signing key"
  fi
}

# identity_check_pending_uploads <resolved lines> — clear github-keys-* steps
# that are done (used by doctor).
identity_check_pending_uploads() {
  local org dir email user key owners me
  grep -q '^github-keys-' "$MACOS_PENDING" 2>/dev/null || return 0
  me="$(gh api user -q .login 2>/dev/null || true)"
  while IFS='|' read -r org dir email user key owners; do
    [ -n "$org" ] && [ -n "$key" ] && [ -n "$user" ] && [ "$user" != "$me" ] || continue
    identity_other_account "$org" "$user" "$(key_material "$key")"
  done <<EOF
$1
EOF
}

# --- GitHub host keys ------------------------------------------------------

# identity_known_hosts — pin github.com's host keys in ~/.ssh/known_hosts,
# taken from GitHub's API over authenticated HTTPS (not trust-on-first-use
# ssh-keyscan). Without them a fresh Mac's first ssh to GitHub stops to ask,
# and non-interactive runs (BatchMode, `macos update`) fail.
identity_known_hosts() {
  local file="$HOME/.ssh/known_hosts" keys key added=0
  keys="$(gh api meta -q '.ssh_keys[]' 2>/dev/null || true)"
  if [ -z "$keys" ]; then
    warn "could not fetch GitHub's host keys; the first ssh to GitHub will ask to trust it"
    return 0
  fi
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if [ -f "$file" ] && grep -qxF "github.com $key" "$file"; then
      continue
    fi
    if dry_run; then
      printf '  would add to %s: github.com %s\n' "$file" "${key%% *}" >&2
    else
      printf 'github.com %s\n' "$key" >>"$file"
    fi
    added=$((added + 1))
  done <<EOF
$keys
EOF
  if [ "$added" -gt 0 ]; then
    ok "pinned $added GitHub host key(s) in ~/.ssh/known_hosts (from GitHub's API)"
  else
    skip "GitHub host keys already known"
  fi
}

# --- all -------------------------------------------------------------------

# identity_agent_list — `ssh-add -L` from the agent, or the cached copy from
# the last run it answered (only on a verified Mac).
identity_agent_list() {
  local live
  live="$(SSH_AUTH_SOCK="$OP_AGENT_SOCK" ssh-add -L 2>/dev/null || true)"
  if [ -n "$live" ]; then
    printf '%s\n' "$live"
  elif [ -f "$IDENTITY_VERIFIED" ] && [ -f "$IDENTITY_KEY_CACHE" ]; then
    cat "$IDENTITY_KEY_CACHE"
  fi
}

identity_apply() {
  local lines keys="" list live=0
  lines="$(orgs_lines)" || exit 1
  if [ -z "$lines" ]; then
    skip "no identities in $(orgs_file | sed "s#$HOME#~#") yet; git keeps the stowed defaults"
    return 0
  fi

  if identity_wait_agent; then
    live=1
    identity_link_agent
  elif [ -f "$IDENTITY_VERIFIED" ]; then
    # Closed or locked 1Password on a Mac verified before: keep signing and
    # the ssh pins by rendering from the keys it served last time.
    skip "1Password is not answering; using the keys it served at the last verified run"
  fi
  list="$(identity_agent_list)"
  keys="$(awk 'NF >= 2 { print $1, $2 }' <<<"$list")"
  if [ "$live" = 1 ] && dry_run && [ -z "$keys" ]; then
    keys="(dry run)"
  fi
  lines="$(orgs_resolve "$lines" "$list")"
  identity_render "$lines" "$keys"

  if [ "$live" = 0 ]; then
    if [ -z "$keys" ]; then
      skip "ssh config and signing wait for the 1Password agent"
    fi
    return 0
  fi

  # ssh is linked only now: its IdentityAgent points at 1Password.
  # shellcheck disable=SC2034 # read by stow_packages (lib/dotfiles.sh)
  IDENTITY_READY=1
  if [ ! -f "$IDENTITY_VERIFIED" ]; then
    printf 'verified %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" | write_file "$IDENTITY_VERIFIED"
  fi
  if ! dry_run && [ -n "$list" ] && [ "$(cat "$IDENTITY_KEY_CACHE" 2>/dev/null)" != "$list" ]; then
    (umask 077 && printf '%s\n' "$list" >"$IDENTITY_KEY_CACHE")
  fi
  dotfiles_link
  identity_known_hosts
  identity_upload_keys "$lines"
  if [ "$(gh config get git_protocol -h github.com 2>/dev/null)" != ssh ]; then
    run gh config set git_protocol ssh -h github.com
    ok "gh git protocol → ssh (through the 1Password agent)"
  fi
}
