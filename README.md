# macos

A small, declarative Bash engine that sets up and maintains my Macs. It covers:

- **Apps:** Homebrew formulae, casks and Mac App Store apps, declared in per-profile Brewfiles. It installs them, and it can prune anything a Brewfile no longer lists.
- **Dotfiles:** GNU Stow packages from a separate private repo.
- **macOS defaults:** declared settings, each read back after writing so the tool can tell whether it took effect.
- **Identity:** the 1Password SSH agent, SSH commit signing, and per-org git identities.
- **Profiles:** `base` plus one of `work` or `personal`.

> **Status: Phase 5 (defaults).** Bootstrap, `apply`, `upgrade`, `apps`, `dotfiles` and `defaults` work. Identity, `doctor`, `update` and `uninstall` are still placeholders that exit with code `2`. See [Roadmap](#roadmap).

## Engine vs. data

This repo is only the **engine**. It holds no personal data. Everything personal lives in a private dotfiles repo (by default `ar4mirez/macos-dotfiles`, cloned to `~/.dotfiles`):

```
~/.dotfiles/
  macos/profiles/{base,work,personal}/
      Brewfile        apps for this profile
      defaults.conf   domain | key | type | value
      dock.conf       Dock layout
      stow.list       Stow packages to link
  macos/orgs.conf     per-org git identity
  zsh/ git/ ssh/ …    Stow packages
```

| Path | Owner | Notes |
|---|---|---|
| `~/.local/share/macos` | engine (this repo) | Replaced on `macos update`. Never edit it. |
| `~/.dotfiles` | you (private repo) | Your apps, settings and configs. Edit and commit here. |
| `~/.local/state/macos` | generated | `machine.env`, merged Brewfile, logs, backups, pending manual steps |

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ar4mirez/macos/main/boot.sh | bash
# or non-interactively:
curl -fsSL https://raw.githubusercontent.com/ar4mirez/macos/main/boot.sh | bash -s -- --yes --profile work --hostname "Studio"
```

`boot.sh` sets up the prerequisites and then hands over to `macos bootstrap`:
1. Installs the Xcode Command Line Tools and Homebrew if they're missing.
2. Clones this engine to `~/.local/share/macos`.

`macos bootstrap` then runs these steps. Each is idempotent, so re-running resumes:

1. **Profile and computer name:** asks on the terminal, then saves them to `~/.local/state/macos/machine.env`.
2. **Prerequisites:** installs `gh`.
3. **Security baseline:** Touch ID for `sudo` (via `/etc/pam.d/sudo_local`, which survives OS updates), firewall and stealth mode, Homebrew analytics off, hostname.
4. **GitHub:** logs `gh` in, or adds missing scopes (`admin:public_key`, `admin:ssh_signing_key`). Git uses HTTPS until the 1Password SSH agent is verified.
5. **Dotfiles:** clones the private repo over HTTPS, with `gh` as the only credential helper, and turns on its gitleaks hook.
6. **Apps:** merges the base and profile Brewfiles and runs `brew bundle install --no-upgrade`. Steps that need you in the GUI (e.g. Tailscale's system extension) are recorded as pending.

Use `--dry-run` to see every change without making it.

## Commands

```
macos bootstrap   First-run setup of a new Mac
macos apply       Converge apps, dotfiles, defaults and runtimes (--prune, --dry-run)
macos upgrade     Upgrade declared packages and runtimes
macos apps        add | remove | adopt apps in a profile Brewfile
macos dotfiles    link | unlink | status
macos defaults    apply | check
macos identity    1Password SSH agent, git identities, commit signing
macos doctor      Report actual state and pending manual steps
macos update      Pull engine + dotfiles, run migrations, apply
macos uninstall   Unlink dotfiles, remove the engine (apps are left alone)
```

## Managing apps

The profile Brewfiles in the dotfiles repo are the source of truth. This Mac uses `base` plus the profile saved in `machine.env`.

```sh
macos apps add spotify --cask            # declare in this Mac's profile + install
macos apps add jq --profile base         # declare for every Mac
macos apps remove slack                  # undeclare + uninstall (asks first)
macos apps adopt                         # declare brew installs no Brewfile lists yet,
                                         # and hand manually installed apps to Homebrew
macos apply                              # install anything declared but missing (never upgrades)
macos apply --prune                      # also uninstall brew packages no Brewfile declares
macos upgrade                            # upgrade declared packages + mise runtimes
```

- **`apps add` and `apps remove`:** they edit the Brewfiles with `brew bundle add` and `brew bundle remove`, then remind you to commit in `~/.dotfiles`.
  - `add` detects whether a name is a formula or a cask, and asks you to choose when it's both (e.g. `docker`).
  - `add` refuses to duplicate an entry. `brew bundle add` would write it twice.
- **`apply --prune`:**
  - It always shows exactly what it would remove and asks first.
  - It only removes formulae, casks and taps. It never touches App Store apps, VS Code extensions or npm/uv/cargo/go tools, or anything Homebrew didn't install.
  - It also resets Homebrew's tap trust store to what the Brewfiles declare.
- **`upgrade`:** it only *lists* macOS updates, because installing them needs a restart you choose.

## Dotfiles

Each top-level directory of the dotfiles repo is a Stow package that mirrors `$HOME`. The `stow.list` files in `base` and in this Mac's profile choose which packages are linked.

```sh
macos dotfiles status    # linked / missing / conflict per file; exits 1 on drift
macos dotfiles link      # also part of `macos apply` and `macos bootstrap`
macos dotfiles unlink
```

- **Linking:** files are linked one at a time (`stow --no-folding`), so `~/.config` stays a real directory.
- **Files in the way:** anything already at a target path (a real file, or a symlink pointing elsewhere) is moved to `~/.local/state/macos/backup/<timestamp>/` first. `stow --adopt` is never used, so nothing is pulled into the repo.
- **Runtimes:** after linking, `apply` runs `mise install` for the runtimes in the mise package.



```sh
./test/run.sh
```

- The tests run under `/bin/bash` 3.2.
- Every system-mutating tool (`defaults`, `brew`, `sudo`, `killall`, …) is replaced by a stub on `PATH`. This stub is what isolates the tests: `defaults` ignores `$HOME`, so redirecting `HOME` alone would still write the real preferences.
- A guard fails the run if any engine script calls a system tool by absolute path. Tools that exist only off `PATH` (firewall, `activateSettings`, `op-ssh-sign`) are named once, in `lib/sys.sh`, and can be overridden.

Conventions:
- **Bash version:** `bin/macos`, `lib/*.sh` and any subcommand marked `# macos:bash=3` must stay **bash 3.2-safe**, because they run before Homebrew's bash is installed. Every other subcommand runs under bash 4+.
- **Adding a command:** add one file, `libexec/macos-<name>`, with `# macos:summary=` and `# macos:usage=` headers.
- **Script prelude:** every script sources `lib/common.sh`. It provides `set -Eeuo pipefail`, an ERR trap that names the failing `step`, and `on_exit` cleanup hooks.

## Roadmap

1. **Scaffold:** dispatcher, libraries, test harness, CI. *(done)*
2. **Bootstrap:** `boot.sh`, profile selection, security baseline, `gh` auth, HTTPS dotfiles clone, Brewfile install. *(done)*
3. **Apps:** `apply` / `--prune` / `upgrade` / `apps add|remove|adopt`. *(done)*
4. **Dotfiles:** Stow link, unlink and status, with backup of conflicting files; mise runtimes. *(done)*
5. **Defaults:** the `defaults.conf` engine and imperative steps (Dock, Caps Lock, browser, Brave policy). *(done)*
6. **Identity:** 1Password agent, `includeIf` per org, signing keys.
7. **Operations:** migrations, `doctor`, `update`, `uninstall`.

## License

MIT
