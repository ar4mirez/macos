# Make engine state private: logs and backups (which can hold copies of
# dotfiles, ssh config and sudo_local) were created world-readable by
# engines before 2026-09-24.
state="$MACOS_STATE"
[ -d "$state" ] || exit 0
for d in "$state/logs" "$state/backup"; do
  if [ -d "$d" ]; then
    chmod 700 "$d"
    chmod -R go-rwx "$d"
  fi
done
