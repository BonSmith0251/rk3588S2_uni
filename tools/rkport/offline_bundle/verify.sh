#!/usr/bin/env bash
# verify.sh — confirm the offline install is complete and functional.
# Safe to run any time on the offline VM.
set -uo pipefail
pass=0; fail=0; optn=0
ok(){ printf '  [ OK ] %s\n' "$*"; pass=$((pass+1)); }
no(){ printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
opt(){ printf '  [ -- ] %s\n' "$*"; optn=$((optn+1)); }   # optional: not a failure

echo "=== command-line tools ==="
for t in mke2fs e2fsck debugfs dumpe2fs resize2fs sgdisk parted kpartx \
         simg2img dtc mkimage zstd lz4 xz cpio mkpasswd openssl \
         qemu-aarch64-static qemu-system-aarch64 python3; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else no "$t (missing)"; fi
done

echo "=== Rockchip tools ==="
if command -v rkdeveloptool >/dev/null 2>&1; then ok "rkdeveloptool"; else
  no "rkdeveloptool (needed to flash from this Linux box)"; fi
for t in afptool rkImageMaker; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else
    opt "$t (optional — only for building a single update.img)"; fi
done

echo "=== qemu-user is really static ==="
q="$(command -v qemu-aarch64-static || true)"
if [ -n "$q" ] && file "$q" | grep -q 'statically linked\|static-pie'; then
  ok "qemu-aarch64-static is static"
else
  no "qemu-aarch64-static not static — chroot tests will fail"
fi

echo "=== aarch64 binfmt registered ==="
if [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then ok "binfmt qemu-aarch64"; else
  no "binfmt qemu-aarch64 (run: sudo systemctl restart systemd-binfmt)"; fi

echo "=== python GUI deps ==="
if python3 -c 'import PyQt5' 2>/dev/null; then ok "python3-pyqt5"; else no "python3-pyqt5"; fi

echo "=== tool backend selftest (headless) ==="
if [ -f /opt/rkport/tool/rkport.py ]; then
  ST="$(mktemp "${TMPDIR:-/tmp}/rkport_selftest.XXXXXX")"
  if python3 /opt/rkport/tool/rkport.py --selftest >"$ST" 2>&1; then
    ok "rkport --selftest (log: $ST)"
  else no "rkport --selftest failed (log: $ST)"; fi
else
  no "/opt/rkport/tool/rkport.py not installed"
fi

echo
echo "summary: $pass passed, $fail failed, $optn optional not present"
[ "$fail" -eq 0 ] && echo "READY." || echo "Some checks failed — review above."
exit 0
