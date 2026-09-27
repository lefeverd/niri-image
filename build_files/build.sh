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
  gvfs-smb gvfs-mtp  # Nautilus smb:// and phones
  xdg-user-dirs  # creates ~/Documents, ~/Downloads... at login (GNOME pulled it in before)
  ghostty nautilus brightnessctl cava
  jetbrains-mono-fonts
  tuned tuned-ppd
)
APPS=(
  code insync  # insync: no flathub build; code: flatpak sandbox breaks terminal/toolchains
  eid-mw eid-viewer
  gnome-disk-utility btrfs-assistant snapper  # no gparted: its polkit-agent dep drags in gnome-shell + gdm
)
BACKUP=(syncthing restic borgbackup borgmatic gocryptfs)
VIRT=(qemu-kvm libvirt virt-manager virt-install virt-viewer)
CONTAINERS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
HW=(steam-devices android-tools lm_sensors nvme-cli smartmontools simple-scan sane-backends-drivers-scanners)
# needs root or capture caps (sudo can't see brew); htop, tcpdump, vim-enhanced come with base-main
TOOLS=(wireshark nmap strace iotop-c iftop)

# niri Recommends these; DMS covers bar/launcher/lock, ghostty is the terminal
dnf5 -y install --exclude=waybar,fuzzel,alacritty,swaylock \
  "${DESKTOP[@]}" "${APPS[@]}" "${BACKUP[@]}" "${VIRT[@]}" \
  "${CONTAINERS[@]}" "${HW[@]}" "${TOOLS[@]}"

# TODO(brother): MFC-J480DW + brscan4 are i386 RPMs installing into /opt (-> /var/opt on
#   bootc, not shipped with the image). Try driverless IPP/eSCL first; only add if that fails.
# TODO(teamviewer): installs into /opt too; same problem. RustDesk (flatpak) may cover it.

# Guard: nothing may drag a second session/DM into the image
if rpm -q --quiet gdm || rpm -q --quiet gnome-shell; then echo "GNOME session pulled in"; exit 1; fi

### Services
systemctl enable greetd.service docker.service
# DMS for every user (on the laptop the restored ~/.config link does the same)
systemctl --global enable dms.service

### VM networking next to docker
# /etc/docker/daemon.json sets ip-forward-no-drop so docker leaves the FORWARD policy alone (VM NAT).
# libvirt puts its bridges in the libvirt zone only at runtime; a firewalld reload (docker triggers
# one) drops that and VMs lose DHCP, so bind them permanently
sed 's|</zone>|  <interface name="virbr0"/>\n  <interface name="virbr1"/>\n</zone>|' \
  /usr/lib/firewalld/zones/libvirt.xml > /etc/firewalld/zones/libvirt.xml
# nat-nfs: libvirt NAT maps source ports to 1024+ by default, which NFS "secure" exports reject;
# attach test VMs to this network to mount NFS shares from inside the guest
install -m 600 /dev/stdin /etc/libvirt/qemu/networks/nat-nfs.xml <<'XML'
<network>
  <name>nat-nfs</name>
  <forward mode='nat'><nat><port start='1' end='65535'/></nat></forward>
  <bridge name='virbr1' stp='on' delay='0'/>
  <ip address='192.168.123.1' netmask='255.255.255.0'>
    <dhcp><range start='192.168.123.2' end='192.168.123.254'/></dhcp>
  </ip>
</network>
XML
ln -sf ../nat-nfs.xml /etc/libvirt/qemu/networks/autostart/nat-nfs.xml

### Cleanup
dnf5 -y copr disable avengemedia/dms
dnf5 -y copr disable avengemedia/danklinux
rm -f /etc/yum.repos.d/{docker-ce,vscode,insync}.repo
