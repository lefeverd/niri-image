#!/usr/bin/env bash
# Restore /home/<user> from SRC, a copy of it mounted by mount-nas-copy.sh (pre-reinstall NAS copy)
# or mount-backup.sh (borg archive / restic snapshot), which print the SRC to pass.
# Run with sudo from a TTY (Ctrl+Alt+F3) while logged out of niri (not needed for dry): apps would
# rewrite their config mid-copy.
# Usage: sudo ./restore-home.sh [dry] SRC
#   dry   dry run only
#   SRC   the copy of /home/<user>, e.g. /mnt/borg-restore/home/dvd
# Only what restore-home.allow lists comes back. In a VM, anything that syncs or backs up is
# skipped too: the restored backup timers would write to the real repos, and syncthing would come
# up with the laptop's device ID.
set -euo pipefail

die() { echo "ABORT: $*" >&2; exit 1; }
MODE=all SRC=''
while [ $# -gt 0 ]; do
  case $1 in
    dry) MODE=dry ;;
    /*) [ -z "$SRC" ] || die "only one SRC"; SRC=${1%/} ;;
    *) die "usage: $0 [dry] SRC (mount it first with mount-nas-copy.sh or mount-backup.sh)" ;;
  esac
  shift
done
[ -n "$SRC" ] || die "usage: $0 [dry] SRC (mount it first with mount-nas-copy.sh or mount-backup.sh)"
U=${SUDO_USER:-}
H=/home/$U
LOG=/var/log/restore-home-$(date +%Y%m%d-%H%M%S)

[ "$EUID" -eq 0 ] || die "run with sudo"
[ -n "$U" ] && [ "$U" != root ] || die "run via sudo as the user to restore"
[ "$MODE" = dry ] || ! pgrep -u "$U" -x niri >/dev/null || die "log out of niri and run this from a TTY"
# guard against a wrong level (e.g. the mount root instead of <mount>/home/<user>)
[ -d "$SRC" ] || die "$SRC not found"
! mountpoint -q "$SRC" || die "$SRC is a mount root: pass the home folder inside it"
[ -d "$SRC/.config" ] || die "$SRC has no .config: not a home folder"
exec > >(tee -a "$LOG.log") 2>&1

# What comes back is listed in restore-home.allow; the rest stays in the backup
HERE=$(dirname "$(readlink -f "$0")")
PATHS=() REMAP=()
while IFS= read -r l; do
  [[ $l =~ ^[[:space:]]*(#|$) ]] && continue
  if [[ $l == *' => '* ]]; then REMAP+=("${l%% => *}:${l#* => }"); else PATHS+=("$l"); fi
done < "$HERE/restore-home.allow"
while read -r id _; do PATHS+=(".var/app/$id"); done < <(grep -vE '^[[:space:]]*(#|$)' "$HERE/flatpaks.txt")
EXC=(--exclude='/.var/app/*/cache/')

if systemd-detect-virt -q; then
  # test restore: nothing may sync or back up from the VM: no user units (backup timers, syncthing),
  # no autostart (insync), no Syncthing identity, and no Insync state, which without its ~/Insync
  # folder could sync local "deletions" to Drive. Of ~/syncthing only the KeePass db comes back.
  echo "VM detected: restoring the allowlist minus anything that syncs or backs up"
  VM_DROP=" .config/systemd .config/autostart .config/Insync .local/share/Insync .config/syncthing .local/state/syncthing syncthing "
  KEEP=()
  for p in "${PATHS[@]}"; do [[ $VM_DROP == *" $p "* ]] || KEEP+=("$p"); done
  PATHS=("${KEEP[@]}" syncthing/keepass)
fi

# rsync filter: each allowed path, the folders leading to it, nothing else
FILTER=$(mktemp)
trap 'rm -f "$FILTER"' EXIT
{
  for p in "${PATHS[@]}"; do
    d=$p
    while [[ $d == */* ]]; do d=${d%/*}; echo "+ /$d/"; done
    echo "+ /$p"
    echo "+ /$p/***"
  done
  echo "- *"
} | awk '!seen[$0]++' > "$FILTER"

# Same xattr handling as run-copy.sh: the NFS copy has no security.*/system.* xattrs, and
# rsync must not try to strip the SELinux labels of files already in $H
OPTS=(-aHX --numeric-ids --filter='-x security.*' --filter='-x system.*')

copy() {  # args: extra rsync flags (-n first for a dry run)
  rsync "$@" "${OPTS[@]}" "${EXC[@]}" --filter="merge $FILTER" "$SRC/" "$H/"
  for r in "${REMAP[@]}"; do
    local from=${r%%:*} to=${r#*:}
    [ -d "$SRC/$from" ] || continue
    [ "$1" = -n ] || runuser -u "$U" -- mkdir -p "$H/$to"
    rsync "$@" "${OPTS[@]}" "$SRC/$from/" "$H/$to/"
  done
}

# An allowlist fails silently, so show what stays behind: entries at these levels that are
# neither allowed, inside an allowed path, nor on the way to one
skipped() {
  local lvl e rel a
  for lvl in . .config .local .local/share .local/state .var/app; do
    [ -d "$SRC/$lvl" ] || continue
    for e in "$SRC/$lvl"/* "$SRC/$lvl"/.[!.]*; do
      [ -e "$e" ] || [ -L "$e" ] || continue
      rel=${e#"$SRC"/}; rel=${rel#./}
      for a in "${PATHS[@]}" "${REMAP[@]%%:*}"; do
        [[ $rel == "$a" || $rel == "$a"/* || $a == "$rel"/* ]] && continue 2
      done
      printf '  %8s  %s\n' "$(du -sh "$e" 2>/dev/null | cut -f1)" "$rel"
    done
  done
}

echo "== dry run (itemized list: $LOG.dry)"
copy -n -i --stats > "$LOG.dry"
grep -E '^(Number of|Total transferred)' "$LOG.dry"
echo "== left in the backup (not in restore-home.allow; full list: $LOG.skipped)"
skipped | tee "$LOG.skipped"
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
# Thunderbird ties a profile to a hash of its install path: the Flatpak's differs from the RPM's, so
# it finds no profile of its own and starts an empty one. Hand it the profile used last (newest
# prefs.js). Hash taken from the profiles.ini the 157 Flatpak wrote.
TB=$H/.var/app/org.mozilla.thunderbird/.thunderbird TB_HASH=BD520B11F73A6B64
if [ -f "$TB/profiles.ini" ] && ! grep -q "^\[Install$TB_HASH\]" "$TB/profiles.ini"; then
  prof=$(find "$TB" -mindepth 2 -maxdepth 2 -name prefs.js -printf '%T@ %h\n' | sort -rn | head -1)
  prof=${prof##*/}
  if [ -n "$prof" ]; then
    printf '\n[Install%s]\nDefault=%s\nLocked=1\n' "$TB_HASH" "$prof" >> "$TB/profiles.ini"
    printf '\n[%s]\nDefault=%s\nLocked=1\n' "$TB_HASH" "$prof" >> "$TB/installs.ini"
    chown "$U:" "$TB/installs.ini"
    echo "Thunderbird Flatpak -> profile $prof"
  fi
fi
setfacl -m u:qemu:x "$H"  # libvirt reads VM disks/ISOs under $H (pkg-lists/acls-home.txt)
restorecon -R "$H"        # labels were dropped on the NFS copy
echo "units pointing at missing files (remove or ignore):"
[ ! -d "$H/.config/systemd/user" ] || find "$H/.config/systemd/user" -xtype l | sed 's/^/  /'

cat <<EOF
== done. log: $LOG.log
Manual follow-ups:
  - KeePassXC: Settings > Browser Integration, toggle Firefox off/on (rewrites the native-messaging manifest)
  - borgmatic path is templated in homelab-infra: fix it there too, or the next deploy reverts it
EOF
