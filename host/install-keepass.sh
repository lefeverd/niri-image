#!/usr/bin/env bash
# Install KeePass flatpak. It is also installed with the install-flatpaks.sh script, but on a clean install
# it's faster to just install KeePass first.
set -euo pipefail

sudo flatpak install --system -y --noninteractive --or-update flathub  org.keepassxc.KeePassXC

# DMS reads the app list at startup; restart it so the new apps show in the launcher
if systemctl --user -q is-active dms.service; then dms restart; fi
