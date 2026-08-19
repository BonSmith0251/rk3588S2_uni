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
echo "== reused assets =="
for p in vendor_bsp/config/board.conf vendor_bsp/kernel/config/rk3588s_go2_defconfig; do
  if [ -e "$ROOT/$p" ]; then printf "  [ok]   %s\n" "$p"; else printf "  [MISS] %s (import go2-bsp into vendor_bsp/)\n" "$p"; fi
done
echo
echo "Result: $ok present, $miss missing."
[ "$miss" -eq 0 ] || echo "Install the missing tools (see docs/MIGRATION.md step 1) before building."
