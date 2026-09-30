#!/usr/bin/env bash
# Mount the pre-reinstall NAS copy (made by ~/pkg-lists/run-copy.sh) read-only, for restore-home.sh.
# Usage: sudo ./mount-nas-copy.sh
set -euo pipefail

die() { echo "ABORT: $*" >&2; exit 1; }
[ $# -eq 0 ] || die "usage: $0"
U=${SUDO_USER:-}
[ "$EUID" -eq 0 ] || die "run with sudo"
[ -n "$U" ] && [ "$U" != root ] || die "run via sudo as the user to restore"

MNT=/mnt/truenas_laptop_preinstall
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount -t nfs -o vers=4.2,ro truenas.localdomain:/mnt/main/backups/laptop-preinstall "$MNT"
SRC=$MNT/home/$U  # run-copy.sh used rsync -R, so the copy keeps the full path
[ -d "$SRC" ] || die "$SRC not found"

cat <<EOF
== mounted $MNT. Next:
  sudo ./restore-home.sh dry $SRC
  sudo ./restore-home.sh $SRC
System files (/etc, borgmaticfull units) are in $MNT/etc: restore selectively.
Unmount when done: sudo umount $MNT
EOF
