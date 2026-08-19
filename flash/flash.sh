#!/usr/bin/env bash
# GUARDED flash wrapper for the RK3588S2 Go2 SOM.
# Wraps vendor_bsp go2-bsp/scripts/flash.sh with hard safety guards.
#
# This checkout is BUILD-ONLY. Flashing must run on the machine next to the
# robot, with RK_ALLOW_FLASH=1 explicitly set. See docs/RUNBOOK-flash.md.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- Guard 1: opt-in only ------------------------------------------------
if [ "${RK_ALLOW_FLASH:-0}" != "1" ]; then
  cat >&2 <<'EOF'
REFUSING TO FLASH.
This is the build-only workspace. Flashing runs on the machine physically next
to the Go2. To proceed there, re-run with:  RK_ALLOW_FLASH=1 ./flash/flash.sh ...
First rehearse recovery — see docs/RUNBOOK-flash.md.
EOF
  exit 3
fi

# ---- Guard 2: never write identity / userdata ----------------------------
for arg in "$@"; do
  case "$arg" in
    *uni.img|uni|*userdata*|userdata)
      echo "REFUSING: '$arg' targets uni/userdata — per-device identity/state, never flash." >&2
      exit 4;;
  esac
done

# ---- Guard 3: require a verify pass first --------------------------------
if [ "${RK_SKIP_VERIFY:-0}" != "1" ]; then
  echo ">> running pre-flash verify gate..."
  bash "$ROOT/flash/verify.sh" || { echo "verify.sh failed — aborting flash." >&2; exit 5; }
fi

# ---- Guard 4: confirm the golden rollback set is present -----------------
if [ ! -e "$ROOT/flash/golden/SHA256SUMS" ]; then
  echo "REFUSING: no flash/golden/SHA256SUMS — stage the stock rollback set before flashing." >&2
  exit 6
fi

VENDOR_FLASH="${VENDOR_FLASH:-$ROOT/vendor_bsp/analysis/go2-bsp/scripts/flash.sh}"
if [ ! -x "$VENDOR_FLASH" ] && [ ! -f "$VENDOR_FLASH" ]; then
  echo "vendor flash script not found at $VENDOR_FLASH (import go2-bsp into vendor_bsp/)." >&2
  exit 7
fi

echo ">> delegating to $VENDOR_FLASH $*"
echo ">> (device must be in maskrom/loader mode; only boot/rootfs partitions are written)"
exec bash "$VENDOR_FLASH" "$@"
