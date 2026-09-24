# macos

A small, declarative Bash engine that sets up and maintains my Macs. It covers:

- **Apps:** Homebrew formulae, casks and Mac App Store apps, declared in per-profile Brewfiles. It installs them, and it can prune anything a Brewfile no longer lists.
- **Dotfiles:** GNU Stow packages from a separate private repo.
- **macOS settings:** declared `defaults`, Dock layout, Caps Lock, keyboard shortcuts to switch off, default browser and a Brave policy. Each write is read back to confirm it took effect.
- **Identity:** the 1Password SSH agent, SSH commit signing, and per-org git identities.
- **Profiles:** `base` plus one of `work` or `personal`.

> **Status: v0.1.** Every command works. A fresh-VM end-to-end run is still to do (see [Roadmap](#roadmap)).

## Engine vs. data

This repo is only the **engine**. It holds no personal data. Everything personal lives in a private dotfiles repo (by default `ar4mirez/macos-dotfiles`, cloned to `~/.dotfiles`):

```
~/.dotfiles/
  macos/profiles/{base,work,personal}/
      Brewfile            apps for this profile
      defaults.conf       domain | key | type | value
      system.conf         capslock, browser, hotkeys_off (key = value)
      dock.conf           Dock layout (a profile's replaces base's)
      stow.list           Stow packages to link
      brave.json          Brave policies (merged across profiles)
      brave-extensions.conf  extensions installed in every Brave profile
  macos/orgs.conf         git identities (see Identity)
  zsh/ git/ ssh/ …        Stow packages, each mirroring $HOME
```

| Path | Owner | Notes |
|---|---|---|
| `~/.local/share/macos` | engine (this repo) | Replaced on `macos update`. Never edit it. |
| `~/.dotfiles` | you (private repo) | Your apps, settings, Brave extensions and configs. Edit and commit here. |
| `~/.local/state/macos` | generated | `machine.env`, merged Brewfile, logs (private), backups, pending manual steps |

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ar4mirez/macos/main/boot.sh | bash
# or non-interactively:
curl -fsSL https://raw.githubusercontent.com/ar4mirez/macos/main/boot.sh | bash -s -- --yes --profile work --hostname "Studio"
```

`boot.sh` sets up the prerequisites and then hands over to `macos bootstrap`:
1. Installs the Xcode Command Line Tools and Homebrew if they're missing.
2. Clones this engine to `~/.local/share/macos`.

`macos bootstrap` then runs these steps. Each is idempotent, so re-running resumes where it stopped:

1. **Profile and computer name:** asks on the terminal, then saves them to `~/.local/state/macos/machine.env`.
2. **Prerequisites:** installs `gh`, and links `macos` into `~/.local/bin`.
3. **Security baseline:** Touch ID for `sudo` (via `/etc/pam.d/sudo_local`, which survives OS updates), firewall and stealth mode, Homebrew analytics off, hostname.
4. **GitHub:** logs `gh` in, or adds missing scopes (`admin:public_key`, `admin:ssh_signing_key`). Git uses HTTPS until the 1Password SSH agent is verified.
5. **Dotfiles repo:** clones the private repo over HTTPS, with `gh` as the only credential helper, and turns on its gitleaks hook.
6. **Apps:** merges the base and profile Brewfiles and runs `brew bundle install --no-upgrade`. If one app fails, the rest of the setup still runs and bootstrap exits non-zero at the end.
7. **Dotfiles and runtimes:** links the Stow packages, then runs `mise install`.
8. **macOS settings:** applies `defaults.conf`, the Dock layout, Caps Lock, the keyboard shortcuts to switch off, the default browser and the Brave policy.
9. **Identity:** writes the git identities. Once 1Password's SSH agent answers, it also sets up signing and SSH (see [Identity](#identity)).
10. **Migrations and health check:** a fresh Mac marks all migrations as done; a Mac bootstrapped before runs any that are pending. Then `macos doctor`.

Steps that need you in the GUI (1Password sign-in, Tailscale's system extension, confirming the default browser, approving the Brave profile) are recorded as pending, and `macos doctor` lists them. Use `--dry-run` to see every change without making it.

## Commands

```
macos bootstrap   First-run setup of a new Mac
macos apply       Converge apps, dotfiles, runtimes, settings and identity (--prune, --dry-run)
macos upgrade     Upgrade declared packages and runtimes; list macOS updates
macos apps        add | remove | adopt apps in a profile Brewfile
macos dotfiles    link | unlink | status
macos defaults    apply | check
macos identity    1Password SSH agent, git identities, commit signing
macos brave       list | add | remove | adopt extensions for every Brave profile
macos doctor      Report what is actually true, plus pending manual steps
macos update      Pull engine + dotfiles, run migrations, apply
macos uninstall   Unlink dotfiles, remove the engine (apps are left alone)
macos dev         status | link | unlink: run your development clones on this Mac
```

Every command that changes something supports `--dry-run`, takes a lock so two runs never overlap, and logs to `~/.local/state/macos/logs/`.

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

- **`apps add` and `apps remove`:** they edit the Brewfiles with `brew bundle add` and `brew bundle remove`, then install or uninstall just that package. Commit the change in `~/.dotfiles` yourself.
  - `add` detects whether a name is a formula or a cask. When it's both (e.g. `docker`), it stops and asks you to pass `--formula` or `--cask`.
  - `add` refuses to duplicate an entry. `brew bundle add` would write it twice.
  - `remove` also handles taps (`brew untap`). App Store entries are only undeclared; remove the app yourself.
- **`apply --prune`:**
  - It always shows exactly what it would remove and asks first.
  - It only removes formulae, casks and taps. It never touches App Store apps, VS Code extensions or npm/uv/cargo/go tools, or anything Homebrew didn't install.
  - It also resets Homebrew's tap trust store to what the Brewfiles declare, and runs `brew cleanup`.
- **`upgrade`:** it only *lists* macOS updates, because installing them needs a restart you choose.

## Dotfiles

Each top-level directory of the dotfiles repo is a Stow package that mirrors `$HOME`. The `stow.list` files in `base` and in this Mac's profile choose which packages are linked. The `ssh` package is linked only by `macos identity`, once the 1Password agent works.

```sh
macos dotfiles status    # linked / missing / conflict per file; exits 1 on drift
macos dotfiles link      # also part of `macos apply` and `macos bootstrap`
macos dotfiles unlink
```

- **Linking:** files are linked one at a time (`stow --no-folding`), so `~/.config` stays a real directory.
- **Files in the way:** anything already at a target path (a real file, or a symlink pointing elsewhere) is moved to `~/.local/state/macos/backup/<timestamp>/` first. `stow --adopt` is never used, so nothing is pulled into the repo.
- **Machine-only additions:** `~/.zshrc.local` and `~/.config/git/config.local` are sourced or included, but never committed.
- **Runtimes:** after linking, `apply` runs `mise install` for the runtimes in the mise package.

## macOS settings

```sh
macos defaults check     # drift report, read-only; exits 1 if anything differs
macos defaults apply     # also part of `macos apply` and `macos bootstrap`
```

- **`defaults.conf`:** one setting per line, `domain | key | type | value`, with `base` first and the profile overriding it.
  - The domain can be a defaults domain, `-g`, or `@currentHost:<domain>`.
  - A setting counts as applied only when both the value **and** the stored type match. Tap-to-click, for example, must be an `int`, because that's what macOS stores.
  - Every write is read back. Keys that macOS silently ignores are reported, not assumed.
  - Only the affected processes are restarted (Dock, Finder, SystemUIServer, `activateSettings`).
- **`dock.conf`:** the Dock's app section, in order. A profile's `dock.conf` replaces the base one. Apps that aren't installed are skipped, and folders and stacks are left alone.
- **`system.conf`:**
  - `capslock` (`none`/`escape`/`control`). The remap uses `hidutil`, plus a LaunchAgent that re-applies it at each login.
  - `browser`, a bundle ID set with `duti`. macOS asks you to confirm the change once.
  - `hotkeys_off`, the ids of macOS keyboard shortcuts to switch off, such as `60` (select the previous input source, `Ctrl+Space`, which is tmux's prefix). The ids are the keys of `AppleSymbolicHotKeys` in `com.apple.symbolichotkeys`. An id removed from the list stays off; turn it back on in System Settings > Keyboard > Keyboard Shortcuts.
- **Brave:** `brave.json` (policies) and `brave-extensions.conf` (extensions) become one user configuration profile, which you approve in System Settings whenever it changes. See [Brave extensions](#brave-extensions).

## Brave extensions

Chromium keeps a hand-installed extension in one browser profile only. Extensions declared as **policy** are installed in **every** Brave profile, including profiles created later. `brave-extensions.conf` declares them:

```
id                               | name      | mode   | pin
aeblfdkhhhdcdjpifhhbdiojplfjncoa | 1Password | normal | pin
```

- **`mode`:** `normal` extensions install automatically and can be turned off in a profile, but not removed. `force` extensions can't be turned off either.
- **`pin`:** keeps the extension on the toolbar.

```sh
macos brave list                         # declared, whether the active policy has them, hand-installed extras
macos brave add <store url|id> [--pin]   # declare (name looked up on the Chrome Web Store); default profile: base
macos brave remove "<name or id>"
macos brave adopt                        # installed one by hand? declare it so every profile gets it
```

Any change is regenerated into the configuration profile and opened for approval. `defaults check` and `doctor` report it until macOS applies it. Restart Brave afterwards, and each profile installs the extensions on its own.

## Identity

`macos identity` reads `macos/orgs.conf` from the dotfiles repo:

```
org     | directory     | email            | github_user | signing_key          | github_owners
default | ~             | me@example.com   | me          | agent:GitHub personal
acme    | ~/Work/Acme   | me@acme.com      | me          | agent:GitHub Acme    | acme acme-labs
```

- **`default`** is used everywhere else, whatever its position in the file.
- **Other orgs** apply inside their directory and, when `github_owners` is set, in any repo whose remote belongs to those GitHub owners.
- **`signing_key`** is a public key, or `agent:<title>` to take the 1Password key with that item title.
- **A different `github_user`** gets its own SSH host alias, and uploading its keys becomes a pending step.

The work happens in two steps:

1. **Right away:** it writes `~/.config/git/identity.gitconfig`, which the stowed git config includes last.
2. **Once the 1Password SSH agent answers:**
   - It links `~/.1password/agent.sock` and the `ssh` Stow package.
   - It pins GitHub's SSH host keys, fetched from GitHub's API.
   - It turns on SSH commit signing through `op-ssh-sign`, but only for keys the agent actually holds, and writes `allowed_signers`.
   - It uploads missing keys to GitHub, as authentication and signing keys.
   - It switches `gh` to the SSH protocol.

Until the agent answers, the pending list says what to do in 1Password. After that, `macos apply` keeps the verified setup even when 1Password is closed, and never waits for it. If macOS blocks access to 1Password's data folder, run `macos identity` from your own terminal and allow access.

## Keeping it healthy

```sh
macos doctor      # what is actually true: security, apps, dotfiles, settings, identity, pending steps
macos update      # pull engine (fast-forward) + dotfiles (rebase --autostash), run migrations, apply
macos uninstall   # unlink dotfiles, restore the files they replaced, remove the engine
```

- **`doctor`:**
  - It exits 1 only on real problems: FileVault off, declared apps missing, dotfiles not linked, broken commit signing, or the `claude-code` cask shadowing the native install.
  - Drift, uncommitted dotfiles and pending manual steps are warnings.
  - It clears pending steps it can see are done.
- **`update`:**
  - If your uncommitted dotfiles edits conflict with what it pulled, it stops before applying anything. Your edits stay safe in the git stash, and the files go back to the pulled version, so no conflict markers reach your shell.
  - Migrations (`migrations/<unix-timestamp>.sh`) are one-shot fixes for Macs set up by an older engine. Each runs once, in order, and a failing one stops before any later ones.
- **`uninstall`:** it keeps apps, macOS settings, `~/.dotfiles`, and the state directory with its backups.

## Development

Develop in your own clone, not in the installed `~/.local/share/macos`. `make check` runs the suite, `make dev` makes `macos` run your clone, and `macos update` installs what you push. See [docs/development.md](docs/development.md) and [AGENTS.md](AGENTS.md).

```sh
make check        # = ./test/run.sh
```

- The tests run under `/bin/bash` 3.2.
- Every system-mutating tool (`defaults`, `brew`, `sudo`, `killall`, …) is replaced by a stub on `PATH`. This stub is what isolates the tests: `defaults` ignores `$HOME`, so redirecting `HOME` alone would still write the real preferences.
- `defaults` is a stateful stub, so idempotency and read-back can be tested.
- GNU Stow and git run for real, but only against the sandbox.
- A guard fails the run if any engine script calls a system tool by absolute path. Tools that exist only off `PATH` (firewall, `activateSettings`, `op-ssh-sign`) are named once, in `lib/sys.sh`, and can be overridden.

Conventions:
- **Bash version:** `bin/macos`, `lib/*.sh` and any subcommand marked `# macos:bash=3` must stay **bash 3.2-safe**, because they run before Homebrew's bash is installed. Every other subcommand runs under bash 4+.
- **Adding a command:** add one file, `libexec/macos-<name>`, with `# macos:summary=` and `# macos:usage=` headers.
- **Script prelude:** every script sources `lib/common.sh`. It provides `set -Eeuo pipefail`, an ERR trap that names the failing `step`, and `on_exit` cleanup hooks.
- **Pipefail:** with `pipefail` on, `cmd | grep -q` fails whenever `cmd` exits non-zero, even when `grep` matches. Write `{ cmd || true; } | grep -q` when `cmd` can fail. For shell variables use here-strings (`grep -q … <<<"$x"`), never `printf "$x" | grep -q`, which can die of SIGPIPE; a test enforces this.
- **Tripwire:** the test fixtures declare a canary in `com.ar4mirez.macos.test-tripwire`. The suite refuses to start, and fails at the end, if the real `defaults` ever holds it.

## Roadmap

1. **Scaffold:** dispatcher, libraries, test harness, CI. *(done)*
2. **Bootstrap:** `boot.sh`, profile selection, security baseline, `gh` auth, HTTPS dotfiles clone, Brewfile install. *(done)*
3. **Apps:** `apply` / `--prune` / `upgrade` / `apps add|remove|adopt`. *(done)*
4. **Dotfiles:** Stow link, unlink and status, with backup of conflicting files; mise runtimes. *(done)*
5. **Defaults:** the `defaults.conf` engine and imperative steps (Dock, Caps Lock, browser, Brave policy). *(done)*
6. **Identity:** 1Password agent, `includeIf` per org, signing keys, GitHub host keys. *(done)*
7. **Operations:** migrations, `doctor`, `update`, `uninstall`. *(done)*
8. **Fresh-VM end-to-end test:** run `boot.sh` on a clean macOS VM. *(to do; see [docs/e2e-vm.md](docs/e2e-vm.md))*

Not managed on purpose (for now): 1Password's `agent.toml` (its defaults serve every SSH key, which works), and atuin/bat configs (the tools are installed with their defaults). The tmux and Neovim configs live in the dotfiles repo.

## License

MIT
