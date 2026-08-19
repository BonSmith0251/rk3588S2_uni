#!/usr/bin/env bash
# collect.sh — RUN THIS ON AN ONLINE Ubuntu 22.04 (jammy) amd64 machine.
# Produces a fully self-contained offline bundle: a local .deb apt repo +
# Rockchip tools + a generic arm64 guest kernel, plus install/verify scripts.
#
#   ./collect.sh [output_dir]
#
# Then copy the resulting bundle (or its .tar) to the offline VM and run
# install.sh there. Nothing in the offline step touches the network.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/bundle}"
DEBS="$OUT/debs"
TOOLS="$OUT/tools"
GUEST="$OUT/guest"
LOGDIR="$OUT/logs"
STAMP="$(date +%Y%m%d_%H%M%S)"
mkdir -p "$DEBS" "$TOOLS" "$GUEST" "$LOGDIR"
LOG="$LOGDIR/collect_$STAMP.log"
exec > >(tee -a "$LOG") 2>&1

say(){ printf '\n=== %s ===\n' "$*"; }
warn(){ printf '!! %s\n' "$*"; }

say "environment check"
. /etc/os-release 2>/dev/null || true
arch="$(dpkg --print-architecture)"
echo "distro=${VERSION_CODENAME:-?} arch=$arch"
[ "${VERSION_CODENAME:-}" = "jammy" ] || warn "not jammy — debs may not match the offline 22.04 target"
[ "$arch" = "amd64" ] || warn "not amd64 — this bundle targets amd64 hosts"
command -v apt-get >/dev/null || { echo "apt-get missing — not a Debian/Ubuntu host"; exit 1; }

# The collector runs on an ONLINE box, so it installs its own build-host
# prerequisites rather than stopping. Skip with SKIP_PREREQ=1 to manage manually.
say "build-host prerequisites"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
# dpkg-scanpackages→dpkg-dev, apt-ftparchive→apt-utils, plus git/wget and the
# toolchain needed to build rkdeveloptool on this box.
PREREQ="dpkg-dev apt-utils git wget ca-certificates build-essential \
automake autoconf libtool pkg-config libusb-1.0-0-dev"
if [ "${SKIP_PREREQ:-0}" = "1" ]; then
  echo "SKIP_PREREQ=1 — assuming prerequisites are present"
elif command -v dpkg-scanpackages >/dev/null && command -v git >/dev/null \
     && command -v gcc >/dev/null && command -v wget >/dev/null; then
  echo "prerequisites already present"
else
  echo "installing: $PREREQ"
  $SUDO apt-get update -qq || true
  $SUDO apt-get install -y $PREREQ || {
    echo "prereq install failed — run manually:"; echo "  sudo apt-get install -y $PREREQ";
    exit 1; }
fi
command -v dpkg-scanpackages >/dev/null || command -v apt-ftparchive >/dev/null || {
  echo "no Packages index generator (need dpkg-dev or apt-utils)"; exit 1; }

# --- 1. resolve + download the recursive .deb closure -----------------------
say "resolving package closure"
mapfile -t WANT < <(grep -vE '^\s*#|^\s*$' "$HERE/packages.list")
echo "top-level: ${WANT[*]}"
apt-get update -qq || warn "apt-get update failed (stale index may still work)"

# recursive dependency closure (filter virtual/alternatives noise)
CLOSURE="$(apt-cache depends --recurse --no-recommends --no-suggests \
  --no-conflicts --no-breaks --no-replaces --no-enhances "${WANT[@]}" \
  | grep '^\w' | sort -u)"
echo "closure package count: $(wc -l <<<"$CLOSURE")"

say "downloading .debs into $DEBS"
( cd "$DEBS" && echo "$CLOSURE" | xargs -r apt-get download 2>>"$LOG" ) \
  || warn "some apt-get download entries failed (often virtual pkgs — check log)"
echo "debs collected: $(ls -1 "$DEBS"/*.deb 2>/dev/null | wc -l)"

say "building local apt repo index"
( cd "$DEBS"
  # emit UNCOMPRESSED Packages (apt looks for this first) + a .gz copy
  if command -v dpkg-scanpackages >/dev/null; then
    dpkg-scanpackages -m . /dev/null > Packages 2>/dev/null
  else
    apt-ftparchive packages . > Packages
  fi
  gzip -9kf Packages
  # a minimal Release so apt trusts the file:// repo without complaint
  if command -v apt-ftparchive >/dev/null; then
    apt-ftparchive -o APT::FTPArchive::Release::Suite=rkport \
                   -o APT::FTPArchive::Release::Codename=rkport \
                   release . > Release 2>/dev/null || true
  fi
)
echo "wrote $DEBS/Packages (+ .gz, Release): $(grep -c '^Package:' "$DEBS/Packages") packages"

# --- 2. verify the qemu-user-static build is really static ------------------
say "qemu-user-static sanity"
qdeb="$(ls "$DEBS"/qemu-user-static_*.deb 2>/dev/null | head -1)"
if [ -n "$qdeb" ]; then
  tmpd="$(mktemp -d)"; dpkg-deb -x "$qdeb" "$tmpd"
  qbin="$(find "$tmpd" -name 'qemu-aarch64-static' | head -1)"
  if [ -n "$qbin" ] && file "$qbin" | grep -q 'statically linked\|static-pie'; then
    echo "OK: $(basename "$qbin") is static"
  else
    warn "qemu-aarch64-static is NOT static (transitional stub?) — chroot tests will fail."
    warn "On jammy the real static build is 1:6.2; fetch it explicitly if needed."
  fi
  rm -rf "$tmpd"
else
  warn "qemu-user-static deb not downloaded"
fi

# --- 3. Rockchip tools (not in apt): rkbin blobs + rkdeveloptool ------------
say "Rockchip tools"
if command -v git >/dev/null; then
  if git clone --depth 1 https://github.com/rockchip-linux/rkbin "$TOOLS/rkbin" 2>>"$LOG"; then
    echo "rkbin cloned (afptool / rkImageMaker / loaders under tools/rkbin/tools & bin)"
  else warn "rkbin clone failed — add it manually to $TOOLS/rkbin"; fi

  if git clone --depth 1 https://github.com/rockchip-linux/rkdeveloptool \
        "$TOOLS/rkdeveloptool-src" 2>>"$LOG"; then
    say "building rkdeveloptool (needs build-essential libusb-1.0-0-dev pkg-config autoconf automake)"
    if ( cd "$TOOLS/rkdeveloptool-src" && autoreconf -i >>"$LOG" 2>&1 \
         && ./configure >>"$LOG" 2>&1 && make -j"$(nproc)" >>"$LOG" 2>&1 ); then
      cp "$TOOLS/rkdeveloptool-src/rkdeveloptool" "$TOOLS/" && echo "built rkdeveloptool"
    else
      warn "rkdeveloptool build failed — install its build-deps on THIS box and re-run,"
      warn "or drop a prebuilt binary at $TOOLS/rkdeveloptool"
    fi
  fi
else
  warn "git not present — skipping rkbin/rkdeveloptool; add them to $TOOLS manually"
fi

# --- 4. generic arm64 guest kernel for the Tier-3 virt boot test ------------
say "generic arm64 guest kernel (Tier-3 qemu-system boot test)"
KURL="https://cloud-images.ubuntu.com/jammy/current/unpacked/jammy-server-cloudimg-arm64-vmlinuz-generic"
if command -v wget >/dev/null && wget -q -O "$GUEST/vmlinuz-arm64-generic" "$KURL"; then
  echo "fetched generic arm64 kernel -> guest/vmlinuz-arm64-generic"
else
  warn "could not fetch a generic arm64 kernel; drop one at $GUEST/vmlinuz-arm64-generic"
  warn "(only needed for the optional full-system boot tier)"
fi

# --- 5. stage the offline scripts + the tool + checksums --------------------
say "staging offline scripts, tool, checksums"
cp "$HERE/install.sh" "$HERE/verify.sh" "$HERE/packages.list" "$OUT/" 2>/dev/null || true
mkdir -p "$OUT/tool"; cp "$HERE/../tool/"*.py "$OUT/tool/" 2>/dev/null || true
cp "$HERE/../tool/README.md" "$OUT/tool/" 2>/dev/null || true
# exclude logs/ (still being appended) and the manifest itself
( cd "$OUT" && find . -type f ! -name SHA256SUMS ! -path './logs/*' -exec sha256sum {} + > SHA256SUMS )

say "packaging tarball"
TAR="$HERE/rkport_offline_bundle_${STAMP}.tar"
( cd "$(dirname "$OUT")" && tar -cf "$TAR" "$(basename "$OUT")" )
echo "bundle dir : $OUT"
echo "tarball    : $TAR ($(du -h "$TAR" | cut -f1))"
echo "debs       : $(ls -1 "$DEBS"/*.deb 2>/dev/null | wc -l)"
echo "log        : $LOG"
say "DONE — copy the tarball to the offline VM, extract, and run ./install.sh"
