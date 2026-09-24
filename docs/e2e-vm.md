# End-to-end test in a fresh VM (TODO)

> **Status: not done yet.** Deferred on 2026-09-23. Every command has been verified on a real Mac that was already set up, and CI covers lint and unit tests, but `boot.sh` has never run on a truly clean Mac.

## Why

The unit tests stub every system tool, and the real-machine checks ran on a Mac that already had Homebrew and `gh`. Only a clean VM exercises the first-run paths:
- the Xcode Command Line Tools and Homebrew installers
- the `curl | bash` bootstrap with no stdin
- `gh auth login` from nothing
- the first dotfiles clone
- the macOS 27 defaults on a pristine user

## Cost

`tart` is installed as a Homebrew cask. The macOS 27 image is about 20–30 GB to download, and you need roughly 60 GB of free disk.

## Procedure

```sh
brew install cirruslabs/cli/tart
tart clone ghcr.io/cirruslabs/macos-tahoe-vanilla:latest macos-e2e   # swap in the macOS 27 image once published
tart run macos-e2e &                                                  # default login: admin / admin
ssh admin@"$(tart ip macos-e2e)"
```

Inside the VM:

```sh
# Non-interactive first pass (the private dotfiles clone needs a token):
export GH_TOKEN=<fine-grained token with read access to ar4mirez/macos-dotfiles>
curl -fsSL https://raw.githubusercontent.com/ar4mirez/macos/main/boot.sh |
  bash -s -- --yes --profile work --hostname e2e-vm

macos doctor                 # expect 0 failures; pending GUI steps are fine
macos apply                  # second run: expect no changes
macos defaults check         # expect no drift, apart from pending browser/Brave approvals
macos dotfiles status        # expect every file linked
```

Then also try the interactive path in the VM's own Terminal. Run it without `--yes`, answer the prompts, and use the `gh` browser login.

## What to check

- Bootstrap succeeds from nothing with `curl | bash`, both with `--yes` and interactively.
- A re-run of bootstrap resumes and changes nothing.
- `.pkg` casks (`tailscale-app`, `zoom`, `microsoft-teams`) install under the sudo keepalive without prompting again.
- mas and iCloud aren't available in the VM, so they must stay optional.
- `macos uninstall` leaves apps and backups in place.

Afterwards: `tart delete macos-e2e`. Record the findings below, then fix them in the engine with tests.

## Findings

_None yet._
