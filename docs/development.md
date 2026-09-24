# Development

This Mac is set up the same way as any other: it runs the **installed** engine, which lives in `~/.local/share/macos` and is put there by `boot.sh`. It also runs the **installed** dotfiles, the clone that the Stow links point into, `~/.dotfiles` by default. Your development clones live somewhere else. On this machine that's `~/Work/Code/ar4mirez/{macos,macos-dotfiles}`.

## The loop

```sh
cd ~/Work/Code/ar4mirez/macos
# edit…
make check          # full suite, sandboxed: safe to run any time
git commit && git push
macos update        # installs it here, exactly as on every other Mac
```

For the dotfiles repo it's the same: edit, commit and push in its dev clone, then run `macos update`.

## Trying changes before pushing

```sh
make dev                                              # `macos` now runs this clone
macos dev link --dotfiles ~/Work/Code/ar4mirez/macos-dotfiles   # dotfile links now point at the dev clone
macos dev status                                      # what is active, and how each clone compares to GitHub
macos dev unlink                                      # back to the installed copies (or: make undev)
```

- **Engine:** `macos dev link --engine <path>` points `~/.local/bin/macos` at the clone's `bin/macos`. The dispatcher follows the link, so the engine in use is the clone.
- **Dotfiles:** `macos dev link --dotfiles <path>` moves the Stow links from the installed clone to the dev clone. Edits there take effect immediately. `machine.env` remembers both locations (`MACOS_DOTFILES`, `MACOS_DOTFILES_INSTALLED`).
- **Next time:** the clone paths are saved (`MACOS_DEV_ENGINE`, `MACOS_DEV_DOTFILES`), so a plain `macos dev link` works.

While dev mode is on:
- **`macos update`:** it updates the **installed** copies, never your clones. It says so, and you pull your clones yourself.
- **`macos doctor`:** it warns that dev mode is on.
- **`macos uninstall`:** it refuses to run until you've unlinked, so it can never delete a clone.

`macos dev unlink` warns you when a clone has work that isn't on GitHub yet. That work won't reach the installed copies until you push and run `macos update`.

## Tests

`./test/run.sh` (or `make test`) runs everything CI runs:
- shellcheck
- a bash 3.2 syntax check of the bootstrap path
- about 190 sandboxed tests

Each test gets its own `HOME`, state directory and `TMPDIR`. Every system-mutating tool is a stub: `defaults` is a stateful stub, while `stow` and `git` run for real inside the sandbox. Prompts read from `/dev/null`, so a test that hits a prompt fails instead of hanging.

To prove a new test catches a bug, run it against the old code in a **copy** of the repo:

```sh
tmp="$(mktemp -d)" && cp -R . "$tmp/old" && git -C "$tmp/old" checkout -q HEAD~1 -- lib libexec
(cd "$tmp/old" && ./test/run.sh)   # the new test should fail here
```
