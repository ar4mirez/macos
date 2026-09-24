# shellcheck shell=bash
# Absolute paths for system tools that are not on PATH. This is the only file
# allowed to name them (test/run.sh enforces it); every path can be overridden
# so tests can point it at a stub. bash-3.2-safe.

: "${SOCKETFILTERFW:=/usr/libexec/ApplicationFirewall/socketfilterfw}"
: "${ACTIVATE_SETTINGS:=/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings}"
: "${OP_SSH_SIGN:=/Applications/1Password.app/Contents/MacOS/op-ssh-sign}"

# Files outside $HOME that the engine manages; overridable for tests.
: "${PAM_SUDO_LOCAL:=/etc/pam.d/sudo_local}"
: "${HOMEBREW_PREFIX:=/opt/homebrew}"

# Where .app bundles installed outside Homebrew live (checked by `apps adopt`).
: "${MACOS_APPLICATIONS_DIRS:=/Applications $HOME/Applications}"
