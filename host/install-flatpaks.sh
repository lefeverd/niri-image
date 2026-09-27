#!/usr/bin/env bash
# Install the Flathub apps listed in flatpaks.txt (system-wide, like the image's flathub remote),
# plus GeForce NOW from NVIDIA's own remote (per-user, as NVIDIA documents it).
# Run as your user after restore-home.sh; asks for sudo once. Safe to re-run: installed apps are updated.
set -euo pipefail

LIST=$(dirname "$(readlink -f "$0")")/flatpaks.txt
[ "$EUID" -ne 0 ] || { echo "run as your user, not root" >&2; exit 1; }

mapfile -t APPS < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$LIST" | grep -v '^$')
echo "== ${#APPS[@]} apps from flathub"
sudo flatpak install --system -y --noninteractive --or-update flathub "${APPS[@]}"

echo "== GeForce NOW"
# the .flatpakrepo carries NVIDIA's GPG key; adding the bare repo URL fails signature checks
flatpak remote-add --user --if-not-exists GeForceNOW \
  https://international.download.nvidia.com/GFNLinux/flatpak/geforcenow.flatpakrepo
flatpak install --user -y --noninteractive --or-update GeForceNOW com.nvidia.geforcenow

# DMS reads the app list at startup; restart it so the new apps show in the launcher
if systemctl --user -q is-active dms.service; then dms restart; fi
