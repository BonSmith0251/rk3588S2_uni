#!/usr/bin/env bash
# Portable end-to-end regression test for the REAL rkport backend.
# Builds a tiny GPT+ext4 fixture and exercises every real operation.
# Run as root on Ubuntu 22.04 (needs e2fsprogs, sgdisk, loop mount, python3).
#
#   sudo tests/selftest.sh
set -e
TOOL="$(cd "$(dirname "$0")/../tool" && pwd)"
W="$(mktemp -d /tmp/rkport_selftest.XXXXXX)"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
chk(){ if eval "$2"; then echo "  [PASS] $1"; pass=$((pass+1)); else echo "  [FAIL] $1"; fail=$((fail+1)); fi; }

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
cd "$TOOL"

# --- fixture: rootfs tree -> ext4 -> GPT disk ---
mkdir -p "$W/src/etc" "$W/src/unitree"
printf 'root:$6$old$oldhash:19000:0:99999:7:::\n' > "$W/src/etc/shadow"
printf '{"Package":"1.0.0"}\n' > "$W/src/unitree/version.json"
UUID=614e0000-0000-4b53-8000-1d28000054a9
mke2fs -t ext4 -b 4096 -L linuxroot -U $UUID -d "$W/src" -F -q "$W/rootfs.img" 32M
DISK="$W/disk.bin"; truncate -s 64M "$DISK"
dd if=/dev/urandom of="$W/boot.img" bs=1M count=4 status=none
sgdisk -o -n 1:2048:+4M -c 1:boot -n 2:10240:+32M -c 2:rootfs -u 2:$UUID "$DISK" >/dev/null
dd if="$W/boot.img" of="$DISK" bs=512 seek=2048 conv=notrunc status=none
dd if="$W/rootfs.img" of="$DISK" bs=512 seek=10240 conv=notrunc status=none

echo "=== rkport real-backend selftest ==="
python3 rkport_cli.py analyze --dump "$DISK" >"$W/an.json" 2>/dev/null
chk "analyze finds boot+rootfs" "grep -q '\"boot\"' '$W/an.json' && grep -q '\"rootfs\"' '$W/an.json'"

python3 rkport_cli.py extract --dump "$DISK" --name boot --out "$W/b.img" >/dev/null 2>&1
chk "boot carve byte-exact" "cmp -s <(dd if='$DISK' bs=512 skip=2048 count=8192 status=none) '$W/b.img'"

python3 rkport_cli.py rebuild-rootfs --dump "$DISK" --name rootfs --out "$W/rb.img" --target-gib 0.06 >/dev/null 2>&1 || true
chk "rebuilt rootfs keeps UUID" "dumpe2fs -h '$W/rb.img' 2>/dev/null | grep -qi '$UUID'"
chk "rebuilt rootfs keeps label" "dumpe2fs -h '$W/rb.img' 2>/dev/null | grep -qi 'linuxroot'"
chk "rebuilt rootfs content intact" "debugfs -R 'cat /unitree/version.json' '$W/rb.img' 2>/dev/null | grep -q 1.0.0"

python3 rkport_cli.py patch --image "$W/rb.img" --accounts root --password NEWpw >/dev/null 2>&1 || true
chk "patched image has new hash" "! debugfs -R 'cat /etc/shadow' '$W/rb.img.patched' 2>/dev/null | grep -q oldhash"
chk "original image untouched (CoW)" "debugfs -R 'cat /etc/shadow' '$W/rb.img' 2>/dev/null | grep -q oldhash"

python3 rkport_cli.py patch-dump --dump "$DISK" --out "$W/pd.img" --accounts root --password fromDump --target-gib 0.06 >/dev/null 2>&1 || true
chk "patch-dump emits patched image" "! debugfs -R 'cat /etc/shadow' '$W/pd.img' 2>/dev/null | grep -q oldhash"

mkdir -p "$W/proj/Image"; cp "$W/rb.img.patched" "$W/proj/Image/rootfs.img"
python3 rkport_cli.py verify --dir "$W/proj/Image" >"$W/v.json" 2>/dev/null
chk "verify reports ext4 clean" "grep -q '\"ext4_clean\": true' '$W/v.json'"

# --- TRUNCATED-but-data-complete dump: the real Go2 scenario ------------------
# A 128 MiB rootfs (no journal, so all used blocks pack low), placed on its own
# disk, then the disk is cut to capture only the first 32 MiB — every real file
# is inside the cut, the tail is free space. Forces the sparse-extend + extract
# path that failed on the real dump before the fix.
mkdir -p "$W/tsrc/etc" "$W/tsrc/unitree"
printf 'root:$6$old$oldhash:19000:0:99999:7:::\n' > "$W/tsrc/etc/shadow"
printf '{"Package":"1.0.0"}\n' > "$W/tsrc/unitree/version.json"
mke2fs -t ext4 -O ^has_journal -b 4096 -L linuxroot -U $UUID -d "$W/tsrc" -F -q "$W/big.img" 128M
TD="$W/tdisk.bin"; truncate -s 160M "$TD"
sgdisk -o -n 1:2048:+128M -c 1:rootfs -u 1:$UUID "$TD" >/dev/null
dd if="$W/big.img" of="$TD" bs=512 seek=2048 conv=notrunc status=none
head -c $(( 2048*512 + 32*1024*1024 )) "$TD" > "$W/tdisk_trunc.bin"
python3 rkport_cli.py rebuild-rootfs --dump "$W/tdisk_trunc.bin" --name rootfs \
        --out "$W/rt.img" --target-gib 0.2 >"$W/rt.log" 2>&1 || true
chk "truncated rebuild extracts real files (not empty)" \
    "debugfs -R 'cat /unitree/version.json' '$W/rt.img' 2>/dev/null | grep -q 1.0.0"
chk "truncated rebuild kept UUID" \
    "dumpe2fs -h '$W/rt.img' 2>/dev/null | grep -qi '$UUID'"
python3 rkport_cli.py patch --image "$W/rt.img" --accounts root --password xx >/dev/null 2>&1 || true
chk "patch on rebuilt truncated rootfs finds /etc/shadow" \
    "debugfs -R 'cat /etc/shadow' '$W/rt.img.patched' 2>/dev/null | grep -q root"

echo
echo "selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "REAL BACKEND OK" || { echo "FAILURES"; exit 1; }
