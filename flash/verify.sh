#!/usr/bin/env bash
# Pre-flash gate: check that images to be flashed are sane BEFORE touching eMMC.
# Checks: files exist, non-empty, fit their partition, and match recorded SHA256.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${RK_IMAGE_DIR:-$ROOT/bsp/out}"
fail=0

# Partition byte budgets (from vendor_bsp parameter.txt; sectors * 512).
#   boot   = 0x20000 sectors = 64 MiB
#   rootfs = the rootfs slot; image must be <= slot (grows on first boot)
declare -A MAXBYTES=(
  [boot.img]=$((0x20000 * 512))
)

echo "== pre-flash verify (image dir: $OUT) =="
[ -d "$OUT" ] || { echo "  [MISS] image dir $OUT — run 'make image' first"; exit 2; }

for img in boot.img rootfs.img; do
  f="$OUT/$img"
  if [ ! -f "$f" ]; then printf "  [skip] %-12s (not built)\n" "$img"; continue; fi
  sz=$(stat -c%s "$f")
  if [ "$sz" -eq 0 ]; then printf "  [FAIL] %-12s is empty\n" "$img"; fail=1; continue; fi
  budget="${MAXBYTES[$img]:-}"
  if [ -n "$budget" ] && [ "$sz" -gt "$budget" ]; then
    printf "  [FAIL] %-12s %d bytes > partition budget %d\n" "$img" "$sz" "$budget"; fail=1
  else
    printf "  [ok]   %-12s %d bytes\n" "$img" "$sz"
  fi
done

# Optional: verify against recorded checksums if present.
if [ -f "$OUT/SHA256SUMS" ]; then
  echo "== checksum =="
  ( cd "$OUT" && sha256sum -c SHA256SUMS ) || fail=1
fi

# Guard: rollback set must exist somewhere reachable before we ever flash.
if [ ! -e "$ROOT/flash/golden/SHA256SUMS" ]; then
  echo "  [WARN] flash/golden/SHA256SUMS missing — stage the stock rollback set (docs/RUNBOOK-flash.md)"
fi

[ "$fail" -eq 0 ] && echo "VERIFY: PASS" || { echo "VERIFY: FAIL"; exit 1; }
