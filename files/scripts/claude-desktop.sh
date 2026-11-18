#!/usr/bin/env bash
# Install the official Claude Desktop (Linux beta) on Fedora.
#
# Anthropic only publishes a .deb, from its apt repository. This script does
# what installing that .deb does on Debian/Ubuntu, the Fedora way:
#   1. Verifies the repository's signed index (InRelease) against Anthropic's
#      pinned signing key, then the Packages index and the .deb by SHA256.
#   2. Installs the Fedora packages matching the .deb's Depends/Recommends.
#   3. Unpacks the .deb's files into /usr (same paths as on Debian).
#   4. Repeats the postinst steps that apply on Fedora: MIME types, the
#      claude:// URL handler, icons, the `ccd` launcher link, and the GNOME
#      search provider (only when GNOME Shell is installed).
# Not repeated from the postinst: the AppArmor profile (Fedora uses SELinux)
# and the apt source entry. On an atomic image updates arrive with each image
# build; on a regular Fedora install, re-run this script to update.
#
# Runs as root: in an image build (BlueBuild `script` module) or on a regular,
# non-atomic Fedora install. Set CLAUDE_COWORK=0 to skip the QEMU/UEFI
# packages that only Cowork's VM needs.
set -euo pipefail

REPO="https://downloads.claude.ai/claude-desktop"
SUITE_URL="$REPO/apt/stable/dists/stable"
# Anthropic Claude Code Release Signing <security@anthropic.com>, the key the
# .deb's postinst writes as the apt repository's signed-by key.
KEY_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
COWORK="${CLAUDE_COWORK:-1}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
# On a booted atomic system /usr is read-only: this belongs in the image build.
if [ -e /run/ostree-booted ]; then
  die "this is a booted atomic system; add this script to the image build instead"
fi

case "$(uname -m)" in
  x86_64)  ARCH=amd64; COWORK_PKGS=(qemu-system-x86-core edk2-ovmf virtiofsd) ;;
  aarch64) ARCH=arm64; COWORK_PKGS=(qemu-system-aarch64-core edk2-aarch64 virtiofsd) ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

# --- 1. Download and verify ---------------------------------------------------
log "Verifying the repository index"
export GNUPGHOME="$TMP/gnupg"
mkdir -m 700 "$GNUPGHOME"
fetch "$REPO/key.asc" "$TMP/key.asc"
gpg --batch --quiet --import "$TMP/key.asc"
fetch "$SUITE_URL/InRelease" "$TMP/InRelease"
# Only the signed part is written to Release; keep parsing to that file.
gpg --batch --status-fd 3 --output "$TMP/Release" --decrypt "$TMP/InRelease" \
  3>"$TMP/gpg-status" 2>/dev/null || die "InRelease signature check failed"
awk -v fpr="$KEY_FPR" '$2 == "VALIDSIG" && $NF == fpr { ok = 1 } END { exit !ok }' \
  "$TMP/gpg-status" || die "InRelease is not signed by $KEY_FPR"

valid_until="$(sed -n 's/^Valid-Until: //p' "$TMP/Release")"
if [ -n "$valid_until" ] && [ "$(date -d "$valid_until" +%s)" -lt "$(date +%s)" ]; then
  die "repository index expired on $valid_until"
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

log "Downloading claude-desktop $version ($ARCH)"
fetch "$REPO/apt/stable/$filename" "$TMP/claude-desktop.deb"
echo "$deb_sha  $TMP/claude-desktop.deb" | sha256sum -c --quiet - || die ".deb checksum mismatch"

# --- 2. Dependencies ----------------------------------------------------------
# Fedora names for the .deb's Depends (and the libraries its binary links).
pkgs=(
  gtk3 libnotify nss nspr xdg-utils at-spi2-core libdrm mesa-libgbm libxcb
  libsecret glib2 libXtst libuuid pipewire-libs xdg-desktop-portal cups-libs
  alsa-lib libxkbcommon
)
# Recommends used by Claude Code inside the app (sandbox, SSH, TLS).
pkgs+=(bubblewrap socat openssh-clients ca-certificates)
# A portal backend: keep whichever the desktop already has.
portal=""
for p in xdg-desktop-portal-kde xdg-desktop-portal-gnome xdg-desktop-portal-gtk; do
  rpm -q --quiet "$p" && portal="$p"
done
[ -n "$portal" ] || pkgs+=(xdg-desktop-portal-gtk)
# Cowork runs its tasks in a QEMU/KVM VM.
[ "$COWORK" = 1 ] && pkgs+=("${COWORK_PKGS[@]}")

missing=()
for p in "${pkgs[@]}"; do rpm -q --quiet "$p" || missing+=("$p"); done
if [ "${#missing[@]}" -gt 0 ]; then
  log "Installing: ${missing[*]}"
  dnf -y install --setopt=install_weak_deps=False "${missing[@]}"
fi

# --- 3. Unpack ----------------------------------------------------------------
log "Unpacking"
mkdir "$TMP/deb" "$TMP/root"
(cd "$TMP/deb" && ar x "$TMP/claude-desktop.deb")
tar -xf "$TMP"/deb/data.tar.* -C "$TMP/root"
S="$TMP/root/usr"
[ -x "$S/lib/claude-desktop/claude-desktop" ] || die "unexpected .deb layout"

rm -rf /usr/lib/claude-desktop
cp -a "$S/lib/claude-desktop" /usr/lib/claude-desktop
chown -R root:root /usr/lib/claude-desktop
# Chromium's setuid sandbox helper, as shipped in the .deb (rwsr-xr-x).
chmod 4755 /usr/lib/claude-desktop/chrome-sandbox
ln -sfn ../lib/claude-desktop/claude-desktop /usr/bin/claude-desktop

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
command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true

# `ccd` terminal launcher, only in builds that ship it.
if [ -x "$RES/bin/ccd" ]; then
  ln -sfn ../lib/claude-desktop/resources/bin/ccd /usr/bin/ccd
fi

if command -v gnome-shell >/dev/null; then
  install -Dm644 "$RES/gnome-search-provider/com.anthropic.Claude.search-provider.ini" \
    /usr/share/gnome-shell/search-providers/com.anthropic.Claude.search-provider.ini
  install -Dm644 "$RES/gnome-search-provider/com.anthropic.Claude.SearchProvider.service" \
    /usr/share/dbus-1/services/com.anthropic.Claude.SearchProvider.service
fi

if [ "$COWORK" = 1 ]; then
  # The app looks for Debian's firmware paths (/usr/share/OVMF, /usr/share/AAVMF).
  # Fedora installs the firmware under /usr/share/edk2; link it there if needed.
  if [ "$ARCH" = amd64 ]; then
    fw_dir=/usr/share/OVMF; fw=OVMF
    code=(/usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE_4M.fd)
    vars=(/usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS_4M.fd)
  else
    fw_dir=/usr/share/AAVMF; fw=AAVMF
    code=(/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw)
    vars=(/usr/share/edk2/aarch64/vars-template-pflash.raw)
  fi
  for kind in CODE VARS; do
    [ -e "$fw_dir/${fw}_$kind.fd" ] && continue
    if [ "$kind" = CODE ]; then cands=("${code[@]}"); else cands=("${vars[@]}"); fi
    for cand in "${cands[@]}"; do
      if [ -e "$cand" ]; then
        mkdir -p "$fw_dir"
        ln -sfn "$cand" "$fw_dir/${fw}_$kind.fd"
        break
      fi
    done
  done
  [ -e "$fw_dir/${fw}_CODE.fd" ] || echo "WARNING: no UEFI firmware found for Cowork in $fw_dir" >&2
  # Cowork needs /dev/vhost-vsock at launch.
  mkdir -p /usr/lib/modules-load.d
  echo vhost_vsock > /usr/lib/modules-load.d/claude-desktop-cowork.conf
fi

# --- Check --------------------------------------------------------------------
for bin in /usr/lib/claude-desktop/claude-desktop "$RES/chrome-native-host"; do
  if ldd "$bin" | grep 'not found'; then die "missing libraries for $bin"; fi
done
log "Installed claude-desktop $version"
