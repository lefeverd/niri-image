#!/usr/bin/env bash
# Restore /home/<user> from the pre-reinstall NAS copy (made by ~/pkg-lists/run-copy.sh), or from a
# borg archive or a restic snapshot (disaster recovery).
# Run with sudo from a TTY (Ctrl+Alt+F3) while logged out of niri (not needed for dry): apps would
# rewrite their config mid-copy.
# Usage: sudo ./restore-home.sh [dry] [--borg REPO::ARCHIVE | --restic REPO [restic options]]
#   dry                  mount + dry run only
#   --borg REPO::ARCHIVE restore from a borg archive (mounted read-only) instead of the NAS copy, e.g.
#                        ssh://borg@soprano.localdomain:30022/backups/dvd-fedora-home::fedora-2026-09-27T09:22:03.370583
#                        Needs the borg SSH key in ~/.ssh/id_borg_backup and, for keyfile repos, the
#                        key in ~/.config/borg/keys (both from KeePass); borg prompts for a passphrase.
#   --restic REPO        restore from a restic snapshot (mounted read-only), e.g.
#                        sftp:u648595@u648595.your-storagebox.de:laptop-home
#     --snapshot ID        short snapshot ID from `restic snapshots` (default: latest)
#     --password-file F    repo password file (default: prompt)
#     --ssh-args ARGS      extra ssh arguments for sftp repos, e.g. "-p 23 -i /home/dvd/.ssh/id_hetzner_restic"
# In a VM, user systemd units are skipped: the restored backup timers would write to the
# real repos, and syncthing would come up with the laptop's device ID.
set -euo pipefail

die() { echo "ABORT: $*" >&2; exit 1; }
MODE=all BORG='' RESTIC='' SNAPSHOT=latest PWFILE='' SSHARGS=''
arg() { [ -n "${2:-}" ] || die "$1 needs a value"; }
while [ $# -gt 0 ]; do
  case $1 in
    dry) MODE=dry ;;
    --borg) arg "$@"; BORG=$2; shift ;;
    --restic) arg "$@"; RESTIC=$2; shift ;;
    --snapshot) arg "$@"; SNAPSHOT=$2; shift ;;
    --password-file) arg "$@"; PWFILE=$2; shift ;;
    --ssh-args) arg "$@"; SSHARGS=$2; shift ;;
    *) die "usage: $0 [dry] [--borg REPO::ARCHIVE | --restic REPO [--snapshot ID] [--password-file F] [--ssh-args ARGS]]" ;;
  esac
  shift
done
[ -z "$BORG" ] || [ -z "$RESTIC" ] || die "--borg and --restic are exclusive"
U=${SUDO_USER:-}
H=/home/$U
LOG=/var/log/restore-home-$(date +%Y%m%d-%H%M%S)

[ "$EUID" -eq 0 ] || die "run with sudo"
[ -n "$U" ] && [ "$U" != root ] || die "run via sudo as the user to restore"
[ "$MODE" = dry ] || ! pgrep -u "$U" -x niri >/dev/null || die "log out of niri and run this from a TTY"

if [ -n "$BORG" ]; then
  MNT=/mnt/borg-restore
  # root runs borg with the user's key; a fresh BORG_BASE_DIR keeps root's borg state out of the
  # way (no "repository relocated" prompts), and the soprano repo is unencrypted
  export BORG_RSH="ssh -i $H/.ssh/id_borg_backup -o StrictHostKeyChecking=accept-new"
  export BORG_KEYS_DIR=$H/.config/borg/keys BORG_BASE_DIR=/var/tmp/restore-home-borg
  export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
  mkdir -p "$MNT"
  if ! mountpoint -q "$MNT"; then
    borg mount "$BORG" "$MNT"
    trap 'borg umount "$MNT"' EXIT  # only a mount this run made; leave a pre-existing one alone
  fi
  SRC=$MNT$H  # borg archives of /home/<user> keep the full path
elif [ -n "$RESTIC" ]; then
  MNT=/mnt/restic-restore
  export RESTIC_REPOSITORY=$RESTIC RESTIC_CACHE_DIR=/var/tmp/restore-home-restic
  if [ -n "$PWFILE" ]; then
    export RESTIC_PASSWORD_FILE=$PWFILE
  else
    read -rsp "restic repository password: " RESTIC_PASSWORD; echo
    export RESTIC_PASSWORD
  fi
  ROPTS=(-o sftp.args="-o StrictHostKeyChecking=accept-new $SSHARGS")
  mkdir -p "$MNT"
  if ! mountpoint -q "$MNT"; then
    # restic mount stays in the foreground: run it in the background and wait for the tree
    restic "${ROPTS[@]}" mount "$MNT" > /var/tmp/restore-home-restic-mount.log 2>&1 &
    RPID=$!
    trap 'umount "$MNT" 2>/dev/null; wait "$RPID" 2>/dev/null' EXIT
    for _ in $(seq 60); do [ -d "$MNT/snapshots" ] && break; sleep 2; done
    [ -d "$MNT/snapshots" ] || die "restic mount failed: $(cat /var/tmp/restore-home-restic-mount.log)"
  fi
  # latest -> snapshots/latest, a specific snapshot -> ids/<id>; both keep the full path
  if [ "$SNAPSHOT" = latest ]; then SRC=$MNT/snapshots/latest$H; else SRC=$MNT/ids/$SNAPSHOT$H; fi
else
  MNT=/mnt/truenas_laptop_preinstall
  mkdir -p "$MNT"
  mountpoint -q "$MNT" || mount -t nfs -o vers=4.2,ro truenas.localdomain:/mnt/main/backups/laptop-preinstall "$MNT"
  SRC=$MNT$H  # run-copy.sh used rsync -R, so the copy keeps the full path
fi
[ -d "$SRC" ] || die "$SRC not found"
exec > >(tee -a "$LOG.log") 2>&1

# Apps that moved to Flatpak: copied straight into their sandbox data dirs instead of $H
REMAP=(
  ".local/share/Steam:.var/app/com.valvesoftware.Steam/.local/share/Steam"
  ".thunderbird:.var/app/org.mozilla.thunderbird/.thunderbird"
  ".config/keepassxc:.var/app/org.keepassxc.KeePassXC/config/keepassxc"
)
EXC=(
  --exclude=/.steam/                    # symlinks into ~/.local/share/Steam; the Steam flatpak keeps its own
  --exclude=/.local/share/containers/   # ~29G of old podman/toolbox storage; images are re-pulled, dev box comes from distrobox.ini
)
for r in "${REMAP[@]}"; do EXC+=(--exclude="/${r%%:*}/"); done
if systemd-detect-virt -q; then
  # test restore: config, dotfiles, browsers, KeePass and IntelliJ only. Nothing may sync or back up from the VM:
  # no user units (backup timers, syncthing), no autostart (insync), and no Insync state, which
  # without its ~/Insync folder could sync local "deletions" to Drive
  echo "VM detected: restoring config, dotfiles, browsers, KeePass and IntelliJ only"
  EXC+=(
    --exclude=/.config/systemd/user/ --exclude=/.config/autostart/ --exclude=/.config/Insync/
    --include=/.config/*** --include=/.ssh/*** --include=/.gnupg/*** --include=/.sdkman/***
    --include=/.local/ --include=/.local/bin/***
    --include=/.local/share/ --include=/.local/share/JetBrains/*** --include=/.local/share/applications/***
    --include=/syncthing/ --include=/syncthing/keepass/*** --include='/kpass*.key'
    --include=/dotfiles/***  # stow repo: ~/.bash_profile and ~/.bash_aliases link into it
    --include=/.mozilla/*** --exclude=/.var/app/com.brave.Browser/cache/  # browsers (bookmarks, profiles)
    --include=/.var/ --include=/.var/app/ --include=/.var/app/com.brave.Browser/***
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
# borg/borgmatic were a venv in /opt; the image ships them in /usr/bin. Stow links (~/.bash_aliases...)
# are resolved so the fix lands in ~/dotfiles, where it shows up as a diff to commit
for f in "$H/.config/systemd/user/borgmatichome.service" "$H/.config/borgmatic.d/home-restore-check.sh" \
         "$H/.bashrc" "$H/.bash_aliases" "$H/.bash_profile" "$H/dotfiles/bash/.bashrc"; do
  [ -e "$f" ] || continue
  f=$(readlink -f "$f")
  if grep -q '/opt/venv/borg/bin/' "$f"; then
    sed -i 's#/opt/venv/borg/bin/#/usr/bin/#g' "$f" && echo "fixed borg path: $f"
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
EOF
if [ -z "$BORG" ]; then  # a home archive has no /etc
  echo "  - system files (/etc, borgmaticfull units) are in $MNT/etc; restore selectively"
  echo "  - NAS copy: sudo umount $MNT"
fi
