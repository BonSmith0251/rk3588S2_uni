#!/usr/bin/env bash
# Maskrom recovery: restore the stock 1:1 image set to bring a bad flash back.
# Run on the flashing machine, device in MASKROM mode. This is the rollback path.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GOLDEN="${RK_GOLDEN_DIR:-$ROOT/flash/golden}"          # stock rkdevtool_image/Image copy
LOADER="${RK_LOADER:-$ROOT/flash/loaders/rk3588_spl_loader_v1.19.113.bin}"
RKDEV="${RKDEVELOPTOOL:-rkdeveloptool}"

echo "== RK3588S2 maskrom recovery =="
command -v "$RKDEV" >/dev/null || { echo "rkdeveloptool not found"; exit 2; }
[ -f "$LOADER" ] || { echo "SPL loader missing: $LOADER"; exit 2; }
[ -d "$GOLDEN" ] || { echo "golden set missing: $GOLDEN (copy the stock rkdevtool_image/Image here)"; exit 2; }

echo ">> 1) device detect (expect a maskrom line):"; "$RKDEV" ld
echo ">> 2) push SPL loader:"; "$RKDEV" db "$LOADER"; sleep 1

# Restore only the stock partitions. uni/userdata are intentionally excluded.
# Offsets are LBAs from parameter.txt; adjust if your golden set differs.
restore () { # restore <lba> <file>
  local lba="$1" f="$GOLDEN/$2"
  [ -f "$f" ] || { echo "   skip $2 (absent)"; return; }
  echo "   wl $lba $2"; "$RKDEV" wl "$lba" "$f"
}
restore 0x40    idbloader.img
restore 0x4000  uboot.img
restore 0x9000  boot.img
restore 0x29000 recovery.img
restore 0x79000 rootfs.img
# NOTE: uni.img (0x8000) and userdata are NEVER restored here by design.

echo ">> 3) reset:"; "$RKDEV" rd
echo "Recovery complete. Watch serial console (ttyFIQ0 @ 1.5 Mbaud) for boot."
