#!/usr/bin/env bash
# install.sh — RUN THIS ON THE OFFLINE Ubuntu 22.04 (jammy) amd64 VM.
# Installs the whole toolchain from the local .deb repo. No network is used.
#
#   sudo ./install.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEBS="$HERE/debs"
TOOLS="$HERE/tools"
STAMP="$(date +%Y%m%d_%H%M%S)"
mkdir -p "$HERE/logs"
LOG="$HERE/logs/install_$STAMP.log"
exec > >(tee -a "$LOG") 2>&1

say(){ printf '\n=== %s ===\n' "$*"; }
warn(){ printf '!! %s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo ./install.sh"; exit 1; }
[ -d "$DEBS" ] || { echo "missing $DEBS — extract the full bundle first"; exit 1; }

say "environment"
. /etc/os-release 2>/dev/null || true
echo "distro=${VERSION_CODENAME:-?} arch=$(dpkg --print-architecture)"
[ "${VERSION_CODENAME:-}" = "jammy" ] || warn "not jammy — installs may be rejected by dependency versions"

say "verifying bundle checksums"
if [ -f "$HERE/SHA256SUMS" ]; then
  ( cd "$HERE" && sha256sum --quiet -c SHA256SUMS ) && echo "checksums OK" \
    || warn "checksum mismatch — bundle may be corrupt/incomplete"
fi

# --- register a local file:// apt repo so dependency ORDER is solved by apt --
say "registering local apt repo"
LIST=/etc/apt/sources.list.d/rkport-offline.list
echo "deb [trusted=yes] file://$DEBS ./" > "$LIST"
# offline: update ONLY this repo, don't touch the (unreachable) network mirrors
apt-get -o Dir::Etc::sourcelist="$LIST" \
        -o Dir::Etc::sourceparts="-" \
        -o APT::Get::List-Cleanup="0" update

say "installing packages from local repo"
mapfile -t WANT < <(grep -vE '^\s*#|^\s*$' "$HERE/packages.list")
apt-get -o Dir::Etc::sourcelist="$LIST" -o Dir::Etc::sourceparts="-" \
        install -y --no-install-recommends "${WANT[@]}" \
  || { warn "apt install failed — falling back to dpkg -i (ordering best-effort)";
       dpkg -i "$DEBS"/*.deb || apt-get -o Dir::Etc::sourceparts="-" -f install -y; }

# --- Rockchip tools ---------------------------------------------------------
say "installing Rockchip tools -> /opt/rkport/tools"
mkdir -p /opt/rkport/tools
[ -d "$TOOLS" ] && cp -r "$TOOLS"/* /opt/rkport/tools/ 2>/dev/null || true
if [ -f /opt/rkport/tools/rkdeveloptool ]; then
  install -m755 /opt/rkport/tools/rkdeveloptool /usr/local/bin/rkdeveloptool
  echo "rkdeveloptool -> /usr/local/bin"
fi
for t in afptool rkImageMaker; do
  f="$(find /opt/rkport/tools/rkbin -name "$t" -type f 2>/dev/null | head -1)"
  [ -n "$f" ] && install -m755 "$f" "/usr/local/bin/$t" && echo "$t -> /usr/local/bin"
done

# --- binfmt for aarch64 (idempotent) ----------------------------------------
say "registering aarch64 binfmt (qemu-user-static)"
systemctl restart systemd-binfmt 2>/dev/null || true
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  # binfmt-support ships the update-binfmts registration; nudge it
  update-binfmts --enable qemu-aarch64 2>/dev/null || true
fi
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] \
  && echo "binfmt qemu-aarch64 active" \
  || warn "qemu-aarch64 binfmt not active — chroot tests need it (see verify.sh)"

# --- copy the tool ----------------------------------------------------------
say "installing the porter tool -> /opt/rkport/tool"
mkdir -p /opt/rkport/tool
cp "$HERE/tool/"*.py /opt/rkport/tool/ 2>/dev/null || true
cat > /usr/local/bin/rkport <<'EOF'
#!/usr/bin/env bash
exec python3 /opt/rkport/tool/rkport.py "$@"
EOF
cat > /usr/local/bin/rkport-cli <<'EOF'
#!/usr/bin/env bash
exec python3 /opt/rkport/tool/rkport_cli.py "$@"
EOF
chmod +x /usr/local/bin/rkport /usr/local/bin/rkport-cli
echo "GUI:      rkport            (destructive ops: sudo rkport)"
echo "CLI:      rkport-cli --help (analyze|project|extract|rebuild-rootfs|patch|patch-dump|verify)"

say "install complete — running verify.sh"
bash "$HERE/verify.sh" || true
echo "log: $LOG"
