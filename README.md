# nvidia-basic &nbsp; [![bluebuild build badge](https://github.com/marcusmt/nvidia-basic/actions/workflows/build.yml/badge.svg)](https://github.com/marcusmt/nvidia-basic/actions/workflows/build.yml)

A debloated Fedora Kinoite (atomic KDE) with the open NVIDIA kernel modules (`nvidia-open`), built daily from [`recipes/recipe.yml`](recipes/recipe.yml) and published to `ghcr.io/marcusmt/nvidia-basic`.

- Base: `ghcr.io/blue-build/base-images/fedora-kinoite-nvidia-open`, Fedora 45
- Apps via Flatpak (Flathub enabled), dev environments via distrobox/devcontainers

## Changes from stock Kinoite

Every package change is in the recipe, with the reason next to it.

- **Added:** fish, Alacritty, Helium (from its official COPR), gcc (for Neovim's tree-sitter parsers), [Claude Desktop](#claude-desktop), and the runtime libraries of the Strata file manager.
- **Removed:** VM guest tools, Asian input methods, Dolphin, Konsole, Kate/KWrite, other unused KDE apps, Akonadi, printer and scanner drivers (driverless printing stays), ModemManager/WWAN, the Samba server, toolbox (distrobox stays) and Firefox.
- **Per user, not in the image:** Strata and Zed, which install and update themselves.

## Installation

Install the official [Fedora Kinoite](https://fedoraproject.org/atomic-desktops/kinoite/), then rebase to this image.

1. Rebase to the unsigned image first, to install the signing keys and policy:
   ```bash
   rpm-ostree rebase ostree-unverified-registry:ghcr.io/marcusmt/nvidia-basic:latest
   ```
   ```bash
   systemctl reboot
   ```
2. Then rebase to the signed image:
   ```bash
   rpm-ostree rebase ostree-image-signed:docker://ghcr.io/marcusmt/nvidia-basic:latest
   ```
   ```bash
   systemctl reboot
   ```

`latest` always points to the newest build, on the Fedora version pinned in the recipe, so a new Fedora release never arrives by surprise. Updates after that are `rpm-ostree upgrade` and a reboot.

## Secure Boot

If it's enabled, enroll the NVIDIA module signing key, then confirm it on the blue MOK screen at the next boot (password `bluebuild`):

```bash
blujust enroll-secure-boot-key
```

To check that the driver loaded: `lsmod | grep nvidia`.

## Claude Desktop

The official Claude Desktop (Linux beta) is built into the image by [`files/scripts/claude-desktop.sh`](files/scripts/claude-desktop.sh). It verifies Anthropic's signed apt repository and unpacks the newest `.deb` into `/usr`, so each image build picks up the newest release.

Cowork runs its tasks in a QEMU/KVM VM. The image already gives every user access to `/dev/kvm` and `/dev/vhost-vsock`; both should show `crw-rw-rw-`:

```bash
ls -l /dev/kvm /dev/vhost-vsock
```

## Trimming

List the menu apps and the package each one comes from:

```bash
for f in /usr/share/applications/*.desktop; do
  grep -q '^NoDisplay=true' "$f" && continue
  pkg=$(rpm -qf --qf '%{NAME}' "$f" 2>/dev/null) || continue
  printf '%-30s %s\n' "$pkg" "$(grep -m1 '^Name=' "$f" | cut -d= -f2-)"
done | sort -u
```

Add anything you don't want to the `dnf` → `remove` block of the recipe. Once the commit is built: `rpm-ostree upgrade` and reboot.

## Rollback

Pick the previous entry at boot or run `rpm-ostree rollback`. To keep a known-good deployment: `sudo ostree admin pin 0`.

## Verification

The images are signed with [Sigstore](https://www.sigstore.dev/)'s [cosign](https://github.com/sigstore/cosign). To verify one, download `cosign.pub` from this repo and run:

```bash
cosign verify --key cosign.pub ghcr.io/marcusmt/nvidia-basic
```
