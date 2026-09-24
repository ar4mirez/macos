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

# Per-user managed preferences written when a configuration profile is
# approved (used to detect an installed Brave policy).
: "${MANAGED_PREFS_DIR:=/Library/Managed Preferences/$USER}"
# LaunchServices handler database (default browser lives here).
: "${LAUNCHSERVICES_PLIST:=$HOME/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist}"

# 1Password's SSH agent socket (the path has a space, so ssh config and
# SSH_AUTH_SOCK use the ~/.1password/agent.sock symlink instead).
: "${OP_AGENT_SOCK:=$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock}"
