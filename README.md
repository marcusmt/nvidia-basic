# nvidia-basic &nbsp; [![bluebuild build badge](https://github.com/marcusmt/nvidia-basic/actions/workflows/build.yml/badge.svg)](https://github.com/marcusmt/nvidia-basic/actions/workflows/build.yml)

Fedora Kinoite (atomic KDE) with the open NVIDIA kernel modules (`nvidia-open`) and nothing else.
Every extra package lives in `recipes/recipe.yml`, with the reason noted next to it.

- Base: `ghcr.io/blue-build/base-images/fedora-kinoite-nvidia-open`, Fedora 45
- Built daily by GitHub Actions and published to `ghcr.io/marcusmt/nvidia-basic`
- Apps via Flatpak (Flathub enabled), dev environments via distrobox/devcontainers

## Installation

> [!WARNING]  
> [This is an experimental feature](https://www.fedoraproject.org/wiki/Changes/OstreeNativeContainerStable), try at your own discretion.

Install the official [Fedora Kinoite](https://fedoraproject.org/atomic-desktops/kinoite/), then rebase to this image:

- First rebase to the unsigned image, to get the proper signing keys and policies installed:
  ```
  rpm-ostree rebase ostree-unverified-registry:ghcr.io/marcusmt/nvidia-basic:latest
  ```
- Reboot to complete the rebase:
  ```
  systemctl reboot
  ```
- Then rebase to the signed image, like so:
  ```
  rpm-ostree rebase ostree-image-signed:docker://ghcr.io/marcusmt/nvidia-basic:latest
  ```
- Reboot again to complete the installation
  ```
  systemctl reboot
  ```

The `latest` tag will automatically point to the latest build. That build will still always use the Fedora version specified in `recipe.yml`, so you won't get accidentally updated to the next major version.

## Secure Boot

If it's enabled, enroll the NVIDIA module signing key and confirm it on the blue MOK screen at the next boot:

```bash
sudo mokutil --import /etc/pki/akmods/certs/akmods-ublue.der
```

If the file has a different name, `ls /etc/pki/akmods/certs/` shows it. To check that the driver loaded: `lsmod | grep nvidia`.

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

## Claude Desktop

The official Claude Desktop (Linux beta) is built into the image by `files/scripts/claude-desktop.sh`, which verifies Anthropic's signed apt repository and installs the newest `.deb` the Fedora way. Each image build picks up the newest release, so it updates with `rpm-ostree upgrade`.

Cowork runs its tasks in a QEMU/KVM VM and needs your user in the `kvm` group. On an atomic system that group only exists in `/usr/lib/group`, so copy it to `/etc/group` first, then log out and back in:

```bash
grep -E '^kvm:' /usr/lib/group | sudo tee -a /etc/group
```

```bash
sudo usermod -aG kvm $USER
```

## Rollback

Pick the previous entry at boot or run `rpm-ostree rollback`. To keep a known-good deployment: `sudo ostree admin pin 0`.

## ISO

If build on Fedora Atomic, you can generate an offline ISO with the instructions available [here](https://blue-build.org/how-to/generate-iso/#_top). These ISOs cannot unfortunately be distributed on GitHub for free due to large sizes, so for public projects something else has to be used for hosting.

## Verification

These images are signed with [Sigstore](https://www.sigstore.dev/)'s [cosign](https://github.com/sigstore/cosign). You can verify the signature by downloading the `cosign.pub` file from this repo and running the following command:

```bash
cosign verify --key cosign.pub ghcr.io/marcusmt/nvidia-basic
```
