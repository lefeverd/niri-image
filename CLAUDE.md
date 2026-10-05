# niri-image

bootc image for dvd's laptop: ublue `base-main:44` + niri + DankMaterialShell, published as `ghcr.io/lefeverd/niri-image`.
Runbook (install, ISO, test VM, restore, rollback, every gotcha found so far): `~/syncthing/notes/reference/fedora/niri-image (bootc).md`. Read it before touching install/VM/restore flows, and update it whenever behaviour changes.

## Where a change goes

- Image (`build_files/build.sh`, `system_files/`): OS, and anything that talks to host programs, libs or devices (Firefox + KeePassXC native messaging, docker, libvirt, backup tools, root-needing tools). Every package line carries a short comment saying why.
- `host/flatpaks.txt`: standalone GUI apps. `host/Brewfile`: user CLI tools. `host/distrobox.ini`: dev libs.
- `host/` is shipped in the image at `/usr/share/niri-image/host/`, so its scripts must work from there (resolve siblings via `$(dirname "$(readlink -f "$0")")`).
- Before assuming something is in the base, check: `podman run --rm ghcr.io/ublue-os/base-main:44 rpm -q <pkg>` (it lacks gcc, git, xdg-user-dirs, gvfs-smb... that GNOME used to pull in).

## Change loop

Claude has no sudo: anything needing it (ISO build, VM, installs on the host) is handed to the user as exact commands.

1. Edit, then `bash -n` and shellcheck: copy the files to a scratch dir and run `podman run --rm -v <dir>:/m:ro,z docker.io/koalaman/shellcheck:stable /m/<file>` (mounting the repo root with `:z` fails on the root-owned ISO in `output/`).
2. `just build` in the background (rootless, ~10 min) → `localhost/niri-image:latest`.
3. Verify the image in a throwaway container: `podman run --rm localhost/niri-image:latest sh -c '...'` with `rpm -q`, file contents, `systemctl --global is-enabled`, `firewall-offline-cmd --check-config`, `virt-xml-validate`.
4. Run `host/` scripts end to end in a container from the image, as a real user: `useradd -u 1000 dvd`, then `setpriv --reuid=1000 --regid=1000 --init-groups env HOME=... bash /h/<script>` (mount `host/` at `/h`). Container quirks: `/mnt` → `/var/mnt` doesn't exist (`mkdir -p /var/mnt`); `systemd-detect-virt` is true, so restore-home.sh takes its VM path; FUSE needs `--device /dev/fuse --cap-add SYS_ADMIN --security-opt label=disable`.
5. The user tests in the `niri-test` VM (`just build-iso` run WITHOUT sudo, then a fresh install, or `bootc upgrade` after CI).

Done = the verification output shows the expected state. Report plainly what was verified and what wasn't (e.g. "only parses", "untested: needs sudo").

## Shipping

- Commit when asked; the user pushes. Machines follow `:latest` on GHCR, so a change reaches the VM/laptop only after push + a green CI run: tell the user to wait for CI before `bootc upgrade`.
- CI (`.github/workflows/build.yml`) also rebuilds twice a week (Mon/Thu). Download timeouts from third-party repos (e.g. download.docker.com) are transient: `gh run rerun <id> --failed`.
- Tags: `latest`, `YYYYMMDD`, `YYYYMMDD-<sha>` (unique, for `bootc switch` pinning). `cleanup.yml` keeps the 30 newest tagged builds.

## Traps

- `/etc` files derived from a package file (e.g. the firewalld `libvirt` zone) are generated in build.sh from the package's copy, not committed as a full copy.
- dnf happily satisfies deps with GNOME (gparted's polkit agent pulled gdm): build.sh fails the build if gdm/gnome-shell appear; keep that guard.
- Borg: access repos with a scratch `BORG_BASE_DIR`. Using a different repo URL than borgmatic with the user's own borg state records a relocation and breaks the next scheduled borgmatic run. The host's `/opt/venv` borg has no FUSE; the image's borg does.
- Secrets (borg/ssh keys, KeePass): pass paths around, read settings with the secret values redacted, and never print key or passphrase contents.
