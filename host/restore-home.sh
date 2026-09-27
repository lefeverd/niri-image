#!/usr/bin/env bash
# Restore /home/<user> from the pre-reinstall NAS copy (made by ~/pkg-lists/run-copy.sh).
# Run with sudo from a TTY (Ctrl+Alt+F3) while logged out of niri (not needed for dry): apps would
# rewrite their config mid-copy.
# Usage: sudo ./restore-home.sh dry   -> mount + dry run only
#        sudo ./restore-home.sh       -> dry run, confirm, copy, post-install fixes
# In a VM, user systemd units are skipped: the restored backup timers would write to the
# real repos, and syncthing would come up with the laptop's device ID.
set -euo pipefail

MODE=${1:-all}
U=${SUDO_USER:-}
H=/home/$U
NFS=truenas.localdomain:/mnt/main/backups/laptop-preinstall
MNT=/mnt/truenas_laptop_preinstall
SRC=$MNT$H
LOG=/var/log/restore-home-$(date +%Y%m%d-%H%M%S)

die() { echo "ABORT: $*" >&2; exit 1; }
[ "$EUID" -eq 0 ] || die "run with sudo"
[ -n "$U" ] && [ "$U" != root ] || die "run via sudo as the user to restore"
[ "$MODE" = dry ] || ! pgrep -u "$U" -x niri >/dev/null || die "log out of niri and run this from a TTY"

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount -t nfs -o vers=4.2,ro "$NFS" "$MNT"
[ -d "$SRC" ] || die "$SRC not found"
exec > >(tee -a "$LOG.log") 2>&1

# Apps that moved to Flatpak: copied straight into their sandbox data dirs instead of $H
REMAP=(
  ".local/share/Steam:.var/app/com.valvesoftware.Steam/.local/share/Steam"
  ".thunderbird:.var/app/org.mozilla.Thunderbird/.thunderbird"
  ".config/keepassxc:.var/app/org.keepassxc.KeePassXC/config/keepassxc"
)
EXC=(
  --exclude=/.steam/                    # symlinks into ~/.local/share/Steam; the Steam flatpak keeps its own
  --exclude=/.local/share/containers/   # ~29G of old podman/toolbox storage; images are re-pulled, dev box comes from distrobox.ini
)
for r in "${REMAP[@]}"; do EXC+=(--exclude="/${r%%:*}/"); done
if systemd-detect-virt -q; then
  # test restore: config, dotfiles, KeePass and IntelliJ only. Nothing may sync or back up from the VM:
  # no user units (backup timers, syncthing), no autostart (insync), and no Insync state, which
  # without its ~/Insync folder could sync local "deletions" to Drive
  echo "VM detected: restoring config, dotfiles, KeePass and IntelliJ only"
  EXC+=(
    --exclude=/.config/systemd/user/ --exclude=/.config/autostart/ --exclude=/.config/Insync/
    --include=/.config/*** --include=/.ssh/*** --include=/.gnupg/*** --include=/.sdkman/***
    --include=/.local/ --include=/.local/bin/***
    --include=/.local/share/ --include=/.local/share/JetBrains/*** --include=/.local/share/applications/***
    --include=/syncthing/ --include=/syncthing/keepass/***
    --include=/dotfiles/***  # stow repo: ~/.bash_profile and ~/.bash_aliases link into it
    --exclude='/*/' --include='/.*' --exclude='*'  # top-level dotfiles, nothing else
  )
  REMAP=("${REMAP[@]:2}")  # keep only the KeePassXC remap
fi

# Same xattr handling as run-copy.sh: the NFS copy has no security.*/system.* xattrs, and
# rsync must not try to strip the SELinux labels of files already in $H
OPTS=(-aHX --numeric-ids --filter='-x security.*' --filter='-x system.*')

copy() {  # args: extra rsync flags (-n first for a dry run)
  rsync "$@" "${OPTS[@]}" "${EXC[@]}" "$SRC/" "$H/"
  for r in "${REMAP[@]}"; do
    local from=${r%%:*} to=${r#*:}
    [ -d "$SRC/$from" ] || continue
    [ "$1" = -n ] || runuser -u "$U" -- mkdir -p "$H/$to"
    rsync "$@" "${OPTS[@]}" "$SRC/$from/" "$H/$to/"
  done
}

echo "== dry run (itemized list: $LOG.dry)"
copy -n -i --stats > "$LOG.dry"
grep -E '^(Number of|Total transferred)' "$LOG.dry"
[ "$MODE" = dry ] && { echo "dry run only"; exit 0; }
read -rp "Proceed with the copy into $H? [y/N] " a
[ "$a" = y ] || die "cancelled"

echo "== copy"
copy --info=progress2

echo "== post-install fixes"
# borgmatic was a venv in /opt; the image ships it in /usr/bin
for f in "$H/.config/systemd/user/borgmatichome.service" "$H/.config/borgmatic.d/home-restore-check.sh"; do
  if [ -f "$f" ]; then
    sed -i 's#/opt/venv/borg/bin/borgmatic#/usr/bin/borgmatic#g' "$f" && echo "fixed borgmatic path: $f"
  fi
done
setfacl -m u:qemu:x "$H"  # libvirt reads VM disks/ISOs under $H (pkg-lists/acls-home.txt)
restorecon -R "$H"        # labels were dropped on the NFS copy
echo "units pointing at missing files (remove or ignore):"
find "$H/.config/systemd/user" -xtype l 2>/dev/null | sed 's/^/  /'

cat <<EOF
== done. log: $LOG.log
Manual follow-ups:
  - KeePassXC: Settings > Browser Integration, toggle Firefox off/on (rewrites the native-messaging manifest)
  - borgmatic path is templated in homelab-infra: fix it there too, or the next deploy reverts it
  - system files (/etc, borgmaticfull units) are in $MNT/etc; restore selectively
  - sudo umount $MNT
EOF
