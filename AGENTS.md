# AGENTS.md

Instructions for anyone, human or agent, changing this repo. Read the [README](README.md) first. The workflow is in [docs/development.md](docs/development.md), and the design in [docs/architecture.md](docs/architecture.md).

## Where things live

| Path | What | Edit it? |
|---|---|---|
| `~/Work/Code/ar4mirez/macos` | this repo, the development clone | **yes** |
| `~/Work/Code/ar4mirez/macos-dotfiles` | the private data repo, development clone | **yes** |
| `~/.local/share/macos` | the **installed** engine that `macos` runs | **never**: only `macos update` changes it |
| `~/.dotfiles` | the **installed** dotfiles, which the Stow links point into | **never** by hand: only `macos update` |
| `~/.local/state/macos` | machine state: machine.env, logs, backups, pending | read only while debugging |

To try uncommitted work on this Mac, run `make dev` (or `macos dev link --engine . --dotfiles <clone>`). Run `make undev` to switch back. After you push, `macos update` installs the change the way it would on any other Mac.

## Rules

- **Tests:**
  - Run `make check` before committing. It runs the whole suite: shellcheck, bash 3.2 syntax, and the sandboxed tests.
  - Every behavior change gets a test, and every bug fix gets a test that fails on the old code.
  - Prove that with a **copy** of the repo, never by stashing in a clone that `macos` is running.
- **bash 3.2:** `boot.sh`, `bin/macos`, `lib/*.sh` and `libexec/macos-bootstrap` must stay bash 3.2-safe, because a fresh Mac has no other bash. Here-strings (`<<<`) are fine; associative arrays, `mapfile` and `${x,,}` are not.
- **pipefail:** with `pipefail` on, `cmd | grep -q` fails whenever `cmd` does. So:
  - Use `grep -q … <<<"$x"` for variables; a test enforces this.
  - Use `{ cmd || true; } | grep -q` when `cmd` can fail.
- **System tools:** tests put stubs first on `PATH`. Tools that live off `PATH` are named only in `lib/sys.sh`, each as an overridable variable; a test enforces this. `defaults` ignores `$HOME`, and a runtime tripwire fails the suite if the real `defaults` is ever reached.
- **Dry run:** every mutation goes through `run`, `write_file` or `sudo_write_file`, so `--dry-run` shows it and does nothing.
- **Idempotency:** a second `macos apply` must change nothing, and must say only "apply finished".
- **Personal data** lives in the dotfiles repo, never here.
- **Commits** are signed through 1Password, with messages that explain *why*. Don't bypass signing; if 1Password is locked, wait for it.
