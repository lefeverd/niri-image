#!/bin/bash
set -ouex pipefail

cp -avf /ctx/system_files/. /

### Third-party repos (removed at the end; the image is rebuilt, never dnf-updated in place)
dnf5 -y copr enable avengemedia/dms
dnf5 -y copr enable avengemedia/danklinux
curl -fsSLo /etc/yum.repos.d/docker-ce.repo https://download.docker.com/linux/fedora/docker-ce.repo
cat > /etc/yum.repos.d/vscode.repo <<'REPO'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
REPO
cat > /etc/yum.repos.d/insync.repo <<'REPO'
[insync]
name=insync repo
baseurl=http://yum.insync.io/fedora/$releasever/
enabled=1
gpgcheck=1
gpgkey=https://d2t3ff60b2tol4.cloudfront.net/repomd.xml.key
REPO
# Belgian eID: the archive RPM ships the repo file + keys
dnf5 -y install https://eid.belgium.be/sites/default/files/software/eid-archive-fedora-2026-1.noarch.rpm

### Packages
DESKTOP=(
  niri xwayland-satellite
  dms dms-greeter greetd matugen cliphist wl-clipboard
  xdg-desktop-portal-gnome xdg-desktop-portal-gtk gnome-keyring
  ghostty nautilus brightnessctl cava
  jetbrains-mono-fonts
  tuned tuned-ppd
)
APPS=(
  thunderbird keepassxc code insync
  eid-mw eid-viewer
  gnome-disk-utility btrfs-assistant snapper  # no gparted: its polkit-agent dep drags in gnome-shell + gdm
)
BACKUP=(syncthing restic borgbackup borgmatic gocryptfs)
VIRT=(qemu-kvm libvirt virt-manager virt-install virt-viewer)
CONTAINERS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
HW=(steam-devices android-tools lm_sensors nvme-cli smartmontools simple-scan sane-backends-drivers-scanners)
TOOLS=(wireshark nmap tcpdump strace htop iotop-c iftop ncdu vim-enhanced stow)

dnf5 -y install "${DESKTOP[@]}" "${APPS[@]}" "${BACKUP[@]}" "${VIRT[@]}" \
  "${CONTAINERS[@]}" "${HW[@]}" "${TOOLS[@]}"

# TODO(brother): MFC-J480DW + brscan4 are i386 RPMs installing into /opt (-> /var/opt on
#   bootc, not shipped with the image). Try driverless IPP/eSCL first; only add if that fails.
# TODO(teamviewer): installs into /opt too; same problem. RustDesk (flatpak) may cover it.

# Guard: nothing may drag a second session/DM into the image
if rpm -q --quiet gdm || rpm -q --quiet gnome-shell; then echo "GNOME session pulled in"; exit 1; fi

### Services
systemctl enable greetd.service docker.service

### Cleanup
dnf5 -y copr disable avengemedia/dms
dnf5 -y copr disable avengemedia/danklinux
rm -f /etc/yum.repos.d/{docker-ce,vscode,insync}.repo
