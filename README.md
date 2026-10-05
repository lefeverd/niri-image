# niri-image

A personal [bootc](https://github.com/bootc-dev/bootc) image: Fedora Atomic 44 on Universal Blue's
[`base-main`](https://github.com/ublue-os/main), with the [niri](https://github.com/YaLTeR/niri) scrollable-tiling
compositor and [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) (DMS).

Image: `ghcr.io/lefeverd/niri-image`, rebuilt on every push and twice a week (Mon/Thu), signed with cosign (`cosign.pub`).

This repo started from [ublue-os/image-template](https://github.com/ublue-os/image-template). The Justfile, the
workflows and the disk-image tooling still come from it; the template's own README is kept in
[docs/image-template.md](docs/image-template.md).

## What's in the image

- **Desktop**: niri, xwayland-satellite, DMS (bar, launcher, notifications, lock), enabled for every user,
  greetd + dms-greeter, ghostty, Nautilus (with SMB and MTP support), GNOME portals and keyring.
  niri's recommended waybar/fuzzel/alacritty/swaylock are left out: DMS covers them.
- **Apps that need host integration**: Firefox (from base-main), VS Code, Insync,
  GNOME Disks, btrfs-assistant + snapper.
- **Containers and VMs**: Docker CE, libvirt/QEMU + virt-manager.
- **Backups and sync**: borg, borgmatic, restic, gocryptfs, syncthing.
- **Tools**: git, gcc/make (Homebrew and rustup need a system compiler), wireshark, nmap, strace, iotop, iftop.
- **Tweaks**:
  - Belgian keyboard (`be-oss`) in the installer and at the LUKS prompt (`kargs.d`).
  - Docker leaves the FORWARD policy alone (`ip-forward-no-drop`), and libvirt's bridges are permanently in
    firewalld's `libvirt` zone, so VM NAT keeps working next to Docker.
  - An extra libvirt network, `nat-nfs`, keeps privileged source ports so VMs can mount NFS shares.
  - Homebrew is put on PATH once installed (`/etc/profile.d/brew.sh`).

Everything else lives outside the image:

| Where             | What                                   | File                                       |
|-------------------|----------------------------------------|--------------------------------------------|
| Flatpak (Flathub) | standalone GUI apps                    | [`host/flatpaks.txt`](host/flatpaks.txt)   |
| Homebrew          | user CLI tools                         | [`host/Brewfile`](host/Brewfile)           |
| distrobox         | dev libraries and toolchains           | [`host/distrobox.ini`](host/distrobox.ini) |
| `$HOME`           | JetBrains Toolbox, nvm, sdkman, rustup |                                            |

## Install

- **Fresh install**: build the ISO (`just build` then `just build-iso`, see below) and boot it. The installer
  points the system at `ghcr.io/lefeverd/niri-image:latest`, so updates come from GHCR.
- **From another Fedora Atomic / bootc system**:
  `sudo bootc switch ghcr.io/lefeverd/niri-image:latest`, then reboot.

## After installing

The `host/` folder is shipped in the image at `/usr/share/niri-image/host/`:

1. Restore `/home`, in two steps:
   - mount the source read-only: `sudo ./mount-nas-copy.sh` (pre-install copy on the NAS) or
     `sudo ./mount-backup.sh --borg REPO[::ARCHIVE] | --restic REPO ...` (latest archive/snapshot by default,
     confirmed before mounting). Each prints the `SRC` to restore from and how to unmount.
   - `sudo ./restore-home.sh [dry] SRC`: copy it into `/home/<user>`, moving app data into its Flatpak
     location and fixing paths, ACLs and SELinux labels.
     In a VM it only restores a safe subset (no backup timers, sync or autostart).
2. `./install-flatpaks.sh`: install the Flatpak apps.
3. `./install-brews.sh`: install Homebrew and the Brewfile.
4. `./create-distrobox.sh [--replace]`: create the `dev` distrobox (compilers, `-devel` libraries). Then
   `distrobox enter dev` to build in it, `distrobox upgrade dev` to update it.

## Updates and rollback

- `sudo bootc upgrade` then reboot. `bootc status` shows the current image.
- `sudo bootc rollback` goes back to the previous deployment.
- Every build is also tagged `YYYYMMDD-<commit>`: `sudo bootc switch ghcr.io/lefeverd/niri-image:<tag>` pins a
  build, `sudo bootc switch ghcr.io/lefeverd/niri-image:latest` follows new builds again. A weekly workflow
  keeps the 30 newest tagged builds.

Verify the signature:

```
cosign verify --key cosign.pub ghcr.io/lefeverd/niri-image:latest
```

## Build and test locally

```
just build        # rootless podman build -> localhost/niri-image:latest
just build-iso    # run WITHOUT sudo: it asks for the password itself (twice)
```

`just build-iso` packages the local image into `output/bootiso/install.iso` with
[bootc-image-builder](https://github.com/osbuild/bootc-image-builder); it doesn't rebuild the image.
Under `sudo` it would skip copying the image into root's storage and build the ISO from a stale copy.

Changes are checked in layers, cheapest first:

1. Inspect the built image in a throwaway container: `podman run --rm localhost/niri-image:latest rpm -q <pkg>`.
2. Run the `host/` scripts in a container from the image.
3. Install the ISO in a VM (UEFI + TPM, `nat-nfs` network, a virtiofs shared folder), or `bootc upgrade` an
   existing VM once CI has published the image.
4. Upgrade the real machine, knowing `bootc rollback` is there.

## Repository layout

| Path                   | Purpose                                                                               |
|------------------------|---------------------------------------------------------------------------------------|
| `Containerfile`        | `FROM base-main:44`, runs `build_files/build.sh`                                      |
| `build_files/build.sh` | repos, packages, services, config generated at build time                             |
| `system_files/`        | copied as-is into the image (greetd config, kernel args, docker and profile.d config) |
| `disk_config/iso.toml` | installer config: locale, keyboard, `bootc switch` to GHCR                            |
| `host/`                | post-install scripts and package lists                                                |
| `.github/workflows/`   | build + sign + push, weekly cleanup of old images                                     |
| `CLAUDE.md`            | notes for working on this repo with Claude Code                                       |
