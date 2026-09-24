#!/bin/bash
# Bootstrap a new Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/ar4mirez/macos/main/boot.sh | bash
#   curl -fsSL …/boot.sh | bash -s -- --profile work --hostname studio
#
# Installs the Xcode Command Line Tools and Homebrew if missing, clones the
# engine to ~/.local/share/macos, then hands over to `macos bootstrap` with any
# arguments given. Runs under the stock /bin/bash 3.2 and reads answers from
# the terminal, since stdin is this script when piped from curl.
#
# Overrides: MACOS_REPO, MACOS_REF (a branch; `macos update` follows it),
# MACOS_ROOT, HOMEBREW_PREFIX, MACOS_TTY.

set -euo pipefail

MACOS_REPO="${MACOS_REPO:-https://github.com/ar4mirez/macos.git}"
MACOS_REF="${MACOS_REF:-main}"
MACOS_ROOT="${MACOS_ROOT:-$HOME/.local/share/macos}"
HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}"
MACOS_TTY="${MACOS_TTY:-/dev/tty}"
export MACOS_TTY

say() { printf '==> %s\n' "$*" >&2; }
die() { printf '  x %s\n' "$*" >&2; exit 1; }

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  die "this setup supports Apple silicon Macs only (found $(uname -s)/$(uname -m))"
fi

# Command Line Tools (git, compilers). The installer is a GUI dialog, so wait.
if ! xcode-select -p >/dev/null 2>&1; then
  say "Installing the Xcode Command Line Tools; accept the dialog that opens."
  xcode-select --install >/dev/null 2>&1 || true
  waited=0
  until xcode-select -p >/dev/null 2>&1; do
    if [ "$waited" -ge "${MACOS_CLT_TIMEOUT:-3600}" ]; then
      die "the Command Line Tools did not finish installing; install them (xcode-select --install) and re-run"
    fi
    sleep "${MACOS_CLT_POLL:-5}"
    waited=$((waited + ${MACOS_CLT_POLL:-5}))
  done
fi

# Homebrew. Its installer needs sudo; authenticate on the terminal first so
# it can run non-interactively.
if [ ! -x "$HOMEBREW_PREFIX/bin/brew" ]; then
  say "Installing Homebrew."
  sudo -v
  installer="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" ||
    die "could not download the Homebrew installer; check the network and re-run"
  NONINTERACTIVE=1 /bin/bash -c "$installer" || die "the Homebrew installer failed (see above)"
fi
[ -x "$HOMEBREW_PREFIX/bin/brew" ] || die "Homebrew is not at $HOMEBREW_PREFIX/bin/brew after installing"
eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"

# The engine is public; no credentials are needed (and the keychain helper is
# kept out of it).
if [ -d "$MACOS_ROOT/.git" ]; then
  say "Updating the engine in $MACOS_ROOT."
  if [ "$(git -C "$MACOS_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$MACOS_REF" ]; then
    git -c credential.helper= -C "$MACOS_ROOT" fetch --quiet origin "$MACOS_REF" &&
      git -C "$MACOS_ROOT" checkout --quiet "$MACOS_REF" ||
      say "could not switch $MACOS_ROOT to $MACOS_REF; continuing with the local copy"
    git -C "$MACOS_ROOT" symbolic-ref -q HEAD >/dev/null ||
      die "MACOS_REF must be a branch (got '$MACOS_REF'); tags and commits leave the engine unable to update"
  fi
  git -c credential.helper= -C "$MACOS_ROOT" pull --ff-only --quiet ||
    say "could not fast-forward $MACOS_ROOT; continuing with the local copy"
else
  say "Cloning the engine into $MACOS_ROOT."
  mkdir -p "$(dirname "$MACOS_ROOT")"
  git -c credential.helper= clone --quiet --branch "$MACOS_REF" "$MACOS_REPO" "$MACOS_ROOT"
fi

if (exec <"$MACOS_TTY") 2>/dev/null; then
  exec "$MACOS_ROOT/bin/macos" bootstrap "$@" <"$MACOS_TTY"
fi
exec "$MACOS_ROOT/bin/macos" bootstrap "$@"
