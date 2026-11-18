#!/usr/bin/env bash
# Install the official Claude Desktop (Linux beta) into the image.
#
# Anthropic only publishes a .deb, from its apt repository. At image build
# time this script:
#   1. Verifies the repository's signed index (InRelease) against Anthropic's
#      pinned signing key, then the Packages index and the .deb by SHA256.
#   2. Checks that the image has the Fedora packages matching the .deb's
#      dependencies (the recipe's dnf module installs the ones it lacks).
#   3. Unpacks the .deb's files into /usr (same paths as on Debian).
#   4. Repeats the .deb's postinst steps that apply here: MIME types, the
#      claude:// URL handler, icons and the `ccd` launcher link.
# Skipped from the postinst: the AppArmor profile (Fedora uses SELinux), the
# apt source entry (each image build picks up the newest release) and the
# GNOME Shell search provider (this is a KDE image).
set -euo pipefail

REPO="https://downloads.claude.ai/claude-desktop"
SUITE_URL="$REPO/apt/stable/dists/stable"
ARCH=amd64
# Anthropic Claude Code Release Signing <security@anthropic.com>, the key the
# .deb's postinst writes as the apt repository's signed-by key.
KEY_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(uname -m)" = x86_64 ] || die "unsupported architecture: $(uname -m)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

# --- 1. Download and verify ---------------------------------------------------
log "Verifying the repository index"
fetch "$REPO/key.asc" "$TMP/key.asc"
gpg --dearmor < "$TMP/key.asc" > "$TMP/key.gpg"
fetch "$SUITE_URL/InRelease" "$TMP/InRelease"
# Only the signed part is written to Release; everything below parses that.
gpgv --status-fd 3 --keyring "$TMP/key.gpg" --output "$TMP/Release" "$TMP/InRelease" \
  3>"$TMP/gpgv-status" || die "InRelease signature check failed"
awk -v fpr="$KEY_FPR" '$2 == "VALIDSIG" && $NF == fpr { ok = 1 } END { exit !ok }' \
  "$TMP/gpgv-status" || die "InRelease is not signed by $KEY_FPR"

valid_until="$(sed -n 's/^Valid-Until: //p' "$TMP/Release")"
if [ -n "$valid_until" ]; then
  expires="$(date -d "$valid_until" +%s)" || die "unreadable Valid-Until: $valid_until"
  [ "$expires" -ge "$(date +%s)" ] || die "repository index expired on $valid_until"
fi

idx="main/binary-$ARCH/Packages"
idx_sha="$(awk -v f="$idx" '/^SHA256:/ { s = 1; next } /^[^ ]/ { s = 0 } s && $3 == f { print $1 }' "$TMP/Release")"
[ -n "$idx_sha" ] || die "no SHA256 for $idx in the index"
# by-hash: fetch exactly the Packages file this InRelease describes.
fetch "$SUITE_URL/main/binary-$ARCH/by-hash/SHA256/$idx_sha" "$TMP/Packages"
echo "$idx_sha  $TMP/Packages" | sha256sum -c --quiet - || die "Packages checksum mismatch"

# Newest claude-desktop entry: "version filename sha256".
read -r version filename deb_sha < <(
  awk 'BEGIN { RS = "" } /(^|\n)Package: claude-desktop\n/ {
         v = f = s = ""
         n = split($0, l, "\n")
         for (i = 1; i <= n; i++) {
           if (l[i] ~ /^Version: /)  v = substr(l[i], 10)
           if (l[i] ~ /^Filename: /) f = substr(l[i], 11)
           if (l[i] ~ /^SHA256: /)   s = substr(l[i], 9)
         }
         print v, f, s
       }' "$TMP/Packages" | sort -V | tail -n 1
) || true
[ -n "${deb_sha:-}" ] || die "claude-desktop not found in $idx"
case "$filename" in pool/*.deb) ;; *) die "unexpected package path: $filename" ;; esac

log "Downloading claude-desktop $version"
fetch "$REPO/apt/stable/$filename" "$TMP/claude-desktop.deb"
echo "$deb_sha  $TMP/claude-desktop.deb" | sha256sum -c --quiet - || die ".deb checksum mismatch"

# --- 2. Dependencies ----------------------------------------------------------
# Fedora names for the .deb's Depends and the libraries its binary links,
# the Recommends Claude Code uses inside the app (sandbox, SSH, TLS), and
# what Cowork's VM needs. Most come with the base image; the recipe's dnf
# module installs the rest.
pkgs=(
  gtk3 libnotify nss nspr xdg-utils at-spi2-core libdrm mesa-libgbm libxcb
  libsecret glib2 libXtst libuuid pipewire-libs cups-libs alsa-lib libxkbcommon
  xdg-desktop-portal xdg-desktop-portal-kde
  bubblewrap socat openssh-clients ca-certificates
  qemu-system-x86-core edk2-ovmf virtiofsd
  binutils
)
missing=()
for p in "${pkgs[@]}"; do rpm -q --quiet "$p" || missing+=("$p"); done
[ "${#missing[@]}" -eq 0 ] || die "add to the recipe's dnf install: ${missing[*]}"

# --- 3. Unpack ----------------------------------------------------------------
log "Unpacking"
mkdir "$TMP/deb" "$TMP/root"
(cd "$TMP/deb" && ar x "$TMP/claude-desktop.deb")
tar -xf "$TMP"/deb/data.tar.* -C "$TMP/root"
S="$TMP/root/usr"
[ -x "$S/lib/claude-desktop/claude-desktop" ] || die "unexpected .deb layout"

cp -a "$S/lib/claude-desktop" /usr/lib/claude-desktop
chown -R root:root /usr/lib/claude-desktop
# Chromium's setuid sandbox helper, as shipped in the .deb (rwsr-xr-x).
chmod 4755 /usr/lib/claude-desktop/chrome-sandbox
ln -s ../lib/claude-desktop/claude-desktop /usr/bin/claude-desktop

install -Dm644 "$S/share/applications/com.anthropic.Claude.desktop" \
  /usr/share/applications/com.anthropic.Claude.desktop
(cd "$S/share/icons" && find . -type f) | while read -r icon; do
  install -Dm644 "$S/share/icons/$icon" "/usr/share/icons/$icon"
done
install -Dm644 "$S/share/doc/claude-desktop/copyright" /usr/share/doc/claude-desktop/copyright
echo "$version" > /usr/share/doc/claude-desktop/VERSION

# --- 4. postinst steps --------------------------------------------------------
RES=/usr/lib/claude-desktop/resources

# .mcpb, .dxt and .skill MIME types.
install -Dm644 "$RES/linux-mime/com.anthropic.Claude.xml" /usr/share/mime/packages/com.anthropic.Claude.xml
update-mime-database /usr/share/mime
# claude:// handler (sign-in returns through it) and icon cache.
update-desktop-database -q /usr/share/applications
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor

# `ccd` terminal launcher, only in builds that ship it.
if [ -x "$RES/bin/ccd" ]; then
  ln -s ../lib/claude-desktop/resources/bin/ccd /usr/bin/ccd
fi

# Cowork's VM: the app looks for the UEFI firmware at Debian's path, which
# Fedora's edk2-ovmf also provides. Fail the build if that ever changes.
[ -e /usr/share/OVMF/OVMF_CODE.fd ] && [ -e /usr/share/OVMF/OVMF_VARS.fd ] \
  || die "edk2-ovmf no longer provides /usr/share/OVMF; Cowork can't find its firmware"
# udev already creates /dev/vhost-vsock (and opening it loads the module);
# loading it at boot is a cheap safeguard for Cowork's launch check.
mkdir -p /usr/lib/modules-load.d
echo vhost_vsock > /usr/lib/modules-load.d/claude-desktop-cowork.conf

# --- Check --------------------------------------------------------------------
for bin in /usr/lib/claude-desktop/claude-desktop "$RES/chrome-native-host"; do
  if ldd "$bin" | grep 'not found'; then die "missing libraries for $bin"; fi
done
log "Installed claude-desktop $version"
