# macos

A small, declarative Bash engine that sets up and maintains my Macs. It covers:

- **Apps:** Homebrew formulae, casks and Mac App Store apps, declared in per-profile Brewfiles. It installs them, and it can prune anything a Brewfile no longer lists.
- **Dotfiles:** GNU Stow packages from a separate private repo.
- **macOS defaults:** declared settings, each read back after writing so the tool can tell whether it took effect.
- **Identity:** the 1Password SSH agent, SSH commit signing, and per-org git identities.
- **Profiles:** `base` plus one of `work` or `personal`.

> **Status: Phase 1 (scaffold).** The command surface, libraries and test harness exist. Most commands are still placeholders and exit with code `2`. See [Roadmap](#roadmap).

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

## Install (coming in Phase 2)

```sh
curl -fsSL https://raw.githubusercontent.com/ar4mirez/macos/main/boot.sh | bash
```

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

## Development

```sh
./test/run.sh
```

- The tests run under `/bin/bash` 3.2.
- Every system-mutating tool (`defaults`, `brew`, `sudo`, `killall`, …) is replaced by a stub on `PATH`. This stub is what isolates the tests: `defaults` ignores `$HOME`, so redirecting `HOME` alone would still write the real preferences.
- A guard fails the run if any engine script calls a system tool by absolute path.

Conventions:
- **Bash version:** `bin/macos`, `lib/*.sh` and any subcommand marked `# macos:bash=3` must stay **bash 3.2-safe**, because they run before Homebrew's bash is installed. Every other subcommand runs under bash 4+.
- **Adding a command:** add one file, `libexec/macos-<name>`, with `# macos:summary=` and `# macos:usage=` headers.
- **Script prelude:** every script sources `lib/common.sh`. It provides `set -Eeuo pipefail`, an ERR trap that names the failing `step`, and `on_exit` cleanup hooks.

## Roadmap

1. **Scaffold:** dispatcher, libraries, test harness, CI. *(done)*
2. **Bootstrap:** `boot.sh`, profile selection, security baseline, `gh` auth, HTTPS dotfiles clone, Brewfile install.
3. **Apps:** `apply` / `--prune` / `upgrade` / `apps add|remove|adopt`.
4. **Dotfiles:** Stow link, unlink and status, with backup of conflicting files.
5. **Defaults:** the `defaults.conf` engine and imperative steps (Dock, Caps Lock, browser).
6. **Identity:** 1Password agent, `includeIf` per org, signing keys.
7. **Operations:** migrations, `doctor`, `update`, `uninstall`.

## License

MIT
