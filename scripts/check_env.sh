#!/usr/bin/env bash
# Verify the build host has what each layer needs. Non-destructive.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ok=0; miss=0

chk () { # chk <cmd> <why>
  if command -v "$1" >/dev/null 2>&1; then
    printf "  [ok]   %-24s %s\n" "$1" "$(command -v "$1")"; ok=$((ok+1))
  else
    printf "  [MISS] %-24s (%s)\n" "$1" "$2"; miss=$((miss+1))
  fi
}

echo "== host =="
uname -a
echo
echo "== BSP build (Layer 1) =="
chk make "build driver"
chk aarch64-none-linux-gnu-gcc "kernel/u-boot cross toolchain (ARM GNU 10.3-2021.07)"
chk dtc "device tree compiler"
chk mkimage "u-boot-tools, FIT packing"
chk bison "kernel build"; chk flex "kernel build"
chk debootstrap "rootfs build"
chk mkfs.ext4 "e2fsprogs, rootfs image"
echo
echo "== Apps (Layer 2) =="
chk cmake "unitree_sdk2 build"
chk aarch64-linux-gnu-gcc "app cross toolchain"
echo
echo "== AI (Layer 3) =="
chk python3 "rknn-toolkit2 (x86 model conversion)"
echo
echo "== QEMU (pre-hardware test) =="
chk qemu-aarch64-static "Tier-2 chroot userland test"
chk qemu-system-aarch64 "Tier-3 full-system boot test"
echo
echo "== reused assets (go2-bsp submodule) =="
GO2_BSP="vendor_bsp/analysis/go2-bsp"
for p in "$GO2_BSP/config/board.conf" "$GO2_BSP/kernel/config/rk3588s_go2_defconfig"; do
  if [ -e "$ROOT/$p" ]; then printf "  [ok]   %s\n" "$p"; else printf "  [MISS] %s (run: make submodules)\n" "$p"; fi
done
# Prebuilt blobs are gitignored in the analysis repo — they must be transferred out-of-band.
if [ -e "$ROOT/$GO2_BSP/kernel/prebuilt/Image" ]; then
  printf "  [ok]   %s/kernel/prebuilt/Image\n" "$GO2_BSP"
else
  printf "  [WARN] %s/kernel/prebuilt/ absent — needed for 'make images' (see docs/MIGRATION.md)\n" "$GO2_BSP"
fi
echo
echo "Result: $ok present, $miss missing."
[ "$miss" -eq 0 ] || echo "Install the missing tools (see docs/MIGRATION.md step 1) before building."
