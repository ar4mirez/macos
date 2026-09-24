# Architecture

This page records the decisions behind the engine and why each was made.

## Engine and data are separate
The engine (this repo, public) holds no personal data. Brewfiles, `defaults.conf`, the Dock layout and org identities all live in the private dotfiles repo, under `macos/`. That way `macos update` can always fast-forward the engine, and your work app list is never published.

## Apps: the Brewfiles are the truth
- `profiles/base/Brewfile`, `profiles/<profile>/Brewfile` and each add-on's Brewfile are concatenated into `~/.local/state/macos/Brewfile`, because `brew bundle --file` takes only one file.
- Add-ons (`MACOS_ADDONS`) are profiles too: `active_profiles` lists base, the profile, then the add-ons, and every per-profile file is read in that order. A Mac has one main profile (`MAIN_PROFILES` in `lib/profile.sh`); any other directory is an add-on.
- `apply` runs `brew bundle install --no-upgrade`, so a second run changes nothing. Upgrades are a separate step, `macos upgrade`, which `macos update` runs after apply succeeds (`--no-upgrade` skips it).
- `apply --prune` removes every brew formula, cask or tap that no Brewfile lists. It always does a dry run first, shows the diff, and asks before `--force`. Pruning has limits:
  - It never touches Mac App Store apps, VS Code extensions, or npm/uv/cargo/go tools; those cleaners are turned off with `HOMEBREW_BUNDLE_CLEANUP_NO_*=1`.
  - It never touches apps Homebrew didn't install, such as the Claude Code native install.
  - Note: `cleanup --force` resets Homebrew's tap trust store to what the Brewfile declares.
- `apps adopt` finds brew installs that aren't declared yet and adds them to a profile.

## Dotfiles: GNU Stow, no ZDOTDIR
- Links are made with `stow --no-folding --restow`.
- Before linking, conflicting files and symlinks the engine doesn't own are moved to `~/.local/state/macos/backup/<ts>/`. `--adopt` is never used.
- `~/.zshrc`, `~/.zprofile` and `~/.zshenv` are thin stowed files that source `~/.config/zsh/*.zsh`, then an unstowed `~/.zshrc.local`. We don't set ZDOTDIR, because installers that hard-code `~/.zshrc` would then write to a file zsh never reads.
- The git config ends by including an unstowed `~/.config/git/config.local`, so tools that run `git config --global` don't dirty the repo.

## Defaults
- `defaults.conf` has one line per setting: `domain | key | type | value`. The domain can be `-g` or `@currentHost:<domain>`.
- Each write is read back, with bools normalised, to confirm it took effect. `defaults check` reports drift and writes nothing.
- Settings that aren't a single key (Dock layout, Caps Lock, keyboard shortcuts, default browser, the Brave policy profile) are named imperative steps, configured by `dock.conf`, `system.conf` and `brave.mobileconfig`.

## Bootstrap constraints
- **No stdin:** under `curl | bash`, stdin is the pipe, so prompts read from `/dev/tty`. `MACOS_PROFILE=… MACOS_YES=1` runs the whole thing without prompts.
- **Old bash:** a fresh Mac only has `/bin/bash` 3.2, so `boot.sh`, `bin/macos`, `lib/` and `bootstrap` must stay 3.2-safe.
- **Clone over HTTPS:** the private dotfiles repo is cloned over HTTPS, with `gh` as the **only** credential helper. SSH isn't usable until 1Password's agent is running, so `gh` stays on `git_protocol https` until identity is verified.
  - `git -c credential.helper=` must come before `-c credential.helper='!gh auth git-credential'`. The empty value clears the Command Line Tools' system `osxkeychain` helper. Otherwise that helper answers first with whatever token it cached earlier and keeps a copy of every new one. After `gh auth refresh`, that cached token is stale, and pushes fail even though `gh` holds the right scopes.
  - The same reset is persisted in each clone's `.git/config`.
- **Manual GUI steps:** some steps can't be scripted: 1Password sign-in and turning on its SSH agent, Tailscale's system-extension approval, App Store sign-in, and approving configuration profiles. They are recorded in `~/.local/state/macos/pending` and shown by `doctor` as warnings.
- **Signing waits for the agent:** commit signing is turned on only once the 1Password agent answers, and only for keys it actually holds. Once verified, later runs keep the setup even while 1Password is closed.
- **Pipefail:** under `set -o pipefail`, `cmd | grep -q` fails whenever `cmd` exits non-zero, even when `grep` matches. `ls` of a blocked folder and `ssh -T` to GitHub both exit non-zero by design, so such checks use `{ cmd || true; } | grep -q`.
- **Autostash conflicts:** `git rebase --autostash` exits 0 even when re-applying the stash conflicts. `update` detects the unmerged state, resets to the pulled version (the edits stay in the stash), and stops before applying.

## Testing
`defaults` ignores `$HOME`, because cfprefsd looks up the real user. So tests isolate themselves by putting stubs for every system tool first on `PATH`, not by redirecting `HOME`. CI runs lint and unit tests. End-to-end runs happen in a macOS VM.
