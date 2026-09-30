#!/usr/bin/env bash
# Mount a borg archive or a restic snapshot of /home/<user> read-only, for restore-home.sh
# (disaster recovery). Without an explicit archive/snapshot, the latest one is shown and confirmed.
# Usage: sudo ./mount-backup.sh --borg REPO[::ARCHIVE] | --restic REPO [restic options]
#   --borg REPO[::ARCHIVE] borg repo, optionally with an archive (default: the last one), e.g.
#                          ssh://borg@soprano.localdomain:30022/backups/dvd-fedora-home::fedora-2026-09-27T09:22:03.370583
#                          Needs the borg SSH key in ~/.ssh/id_borg_backup and, for keyfile repos, the
#                          key in ~/.config/borg/keys (both from KeePass); borg prompts for a passphrase.
#                          borg mount goes to the background: unmount with `sudo borg umount MNT`.
#   --restic REPO          restic repo, e.g. sftp:u648595@u648595.your-storagebox.de:laptop-home
#                          restic mount stays in the foreground: run restore-home.sh from another
#                          TTY, then Ctrl+C here to unmount.
#     --snapshot ID          short snapshot ID from `restic snapshots` (default: latest of /home/<user>)
#     --password-file F      repo password file (default: prompt)
#     --ssh-args ARGS        extra ssh arguments for sftp repos, e.g. "-p 23 -i /home/dvd/.ssh/id_hetzner_restic"
set -euo pipefail

die() { echo "ABORT: $*" >&2; exit 1; }
BORG='' RESTIC='' SNAPSHOT='' PWFILE='' SSHARGS=''
arg() { [ -n "${2:-}" ] || die "$1 needs a value"; }
while [ $# -gt 0 ]; do
  case $1 in
    --borg) arg "$@"; BORG=$2; shift ;;
    --restic) arg "$@"; RESTIC=$2; shift ;;
    --snapshot) arg "$@"; SNAPSHOT=$2; shift ;;
    --password-file) arg "$@"; PWFILE=$2; shift ;;
    --ssh-args) arg "$@"; SSHARGS=$2; shift ;;
    *) die "usage: $0 --borg REPO[::ARCHIVE] | --restic REPO [--snapshot ID] [--password-file F] [--ssh-args ARGS]" ;;
  esac
  shift
done
[ -n "$BORG$RESTIC" ] || die "--borg or --restic is required"
[ -z "$BORG" ] || [ -z "$RESTIC" ] || die "--borg and --restic are exclusive"
U=${SUDO_USER:-}
H=/home/$U
[ "$EUID" -eq 0 ] || die "run with sudo"
[ -n "$U" ] && [ "$U" != root ] || die "run via sudo as the user to restore"

confirm() { read -rp "$1 [y/N] " a; [ "$a" = y ] || die "cancelled"; }
next() {  # args: source dir, unmount instructions
  cat <<EOF
== mounted. Next:
  sudo ./restore-home.sh dry $1
  sudo ./restore-home.sh $1
$2
EOF
}

if [ -n "$BORG" ]; then
  MNT=/mnt/borg-restore
  # root runs borg with the user's key; a fresh BORG_BASE_DIR keeps root's borg state out of the
  # way (no "repository relocated" prompts), and the soprano repo is unencrypted
  export BORG_RSH="ssh -i $H/.ssh/id_borg_backup -o StrictHostKeyChecking=accept-new"
  export BORG_KEYS_DIR=$H/.config/borg/keys BORG_BASE_DIR=/var/tmp/restore-home-borg
  export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
  ! mountpoint -q "$MNT" || die "$MNT is already mounted: sudo borg umount $MNT"
  if [[ $BORG != *::* ]]; then
    IFS=$'\t' read -r ARCHIVE TIME HOST < <(borg list --last 1 --format '{archive}{TAB}{time}{TAB}{hostname}{NL}' "$BORG")
    [ -n "${ARCHIVE:-}" ] || die "no archive in $BORG"
    echo "latest archive: $ARCHIVE ($TIME, host $HOST)"
    confirm "Use this archive?"
    BORG=$BORG::$ARCHIVE
  fi
  mkdir -p "$MNT"
  borg mount "$BORG" "$MNT"
  SRC=$MNT$H  # borg archives of /home/<user> keep the full path
  [ -d "$SRC" ] || { borg umount "$MNT"; die "$SRC not found in ${BORG#*::}"; }
  next "$SRC" "Unmount when done: sudo borg umount $MNT"
else
  MNT=/mnt/restic-restore
  export RESTIC_REPOSITORY=$RESTIC RESTIC_CACHE_DIR=/var/tmp/restore-home-restic
  if [ -n "$PWFILE" ]; then
    export RESTIC_PASSWORD_FILE=$PWFILE
  else
    read -rsp "restic repository password: " RESTIC_PASSWORD; echo
    export RESTIC_PASSWORD
  fi
  ROPTS=(-o sftp.args="-o StrictHostKeyChecking=accept-new $SSHARGS")
  ! mountpoint -q "$MNT" || die "$MNT is already mounted: stop its restic mount (Ctrl+C) or sudo umount $MNT"
  if [ -z "$SNAPSHOT" ]; then
    # restic's own "latest" spans all hosts and paths: pick the latest of this home instead
    SNAP=$(restic "${ROPTS[@]}" snapshots --latest 1 --path "$H" --json)
    SNAPSHOT=$(jq -r '.[-1].short_id // empty' <<<"$SNAP")
    [ -n "$SNAPSHOT" ] || die "no snapshot of $H in $RESTIC"
    echo "latest snapshot of $H: $(jq -r '.[-1] | "\(.short_id) (\(.time), host \(.hostname))"' <<<"$SNAP")"
    confirm "Use this snapshot?"
  fi
  mkdir -p "$MNT"
  # restic mount stays in the foreground: run it in the background, wait for the tree, then wait on it
  restic "${ROPTS[@]}" mount "$MNT" > /var/tmp/restore-home-restic-mount.log 2>&1 &
  RPID=$!
  trap 'umount "$MNT" 2>/dev/null || true; wait "$RPID" 2>/dev/null || true; echo "unmounted $MNT"' EXIT
  trap 'exit 130' INT TERM  # Ctrl+C lands in `wait`: exit through the EXIT trap
  for _ in $(seq 60); do [ -d "$MNT/ids" ] && break; sleep 2; done
  [ -d "$MNT/ids" ] || die "restic mount failed: $(cat /var/tmp/restore-home-restic-mount.log)"
  SRC=$MNT/ids/$SNAPSHOT$H  # snapshots keep the full path
  [ -d "$SRC" ] || die "$SRC not found"
  next "$SRC" "Run them from another TTY, keep this one open; Ctrl+C here to unmount when done."
  wait "$RPID"
fi
