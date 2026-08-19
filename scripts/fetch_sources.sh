#!/usr/bin/env bash
# Fetch and pin every upstream source into third_party/.
# Idempotent: re-running updates each repo to its pinned ref.
# Run inside WSL2 Ubuntu 22.04 (or any Linux x86_64 build host).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TP="$ROOT/third_party"
mkdir -p "$TP"

# name|git url|ref (branch, tag, or commit)
# NOTE: refs are the recommended starting points; pin to a commit once verified.
MANIFEST=$(cat <<'EOF'
rkbin|https://github.com/rockchip-linux/rkbin.git|master
u-boot-rockchip|https://github.com/rockchip-linux/u-boot.git|next-dev
kernel-rockchip-5.10|https://github.com/rockchip-linux/kernel.git|develop-5.10
unitree_sdk2|https://github.com/unitreerobotics/unitree_sdk2.git|main
unitree_ros2|https://github.com/unitreerobotics/unitree_ros2.git|master
rknn-toolkit2|https://github.com/airockchip/rknn-toolkit2.git|master
EOF
)

clone_or_update () {
  local name="$1" url="$2" ref="$3" dir="$TP/$name"
  if [ -d "$dir/.git" ]; then
    echo ">> updating $name -> $ref"
    git -C "$dir" fetch --depth 1 origin "$ref"
    git -C "$dir" checkout -q FETCH_HEAD
  else
    echo ">> cloning $name ($ref)"
    git clone --depth 1 --branch "$ref" "$url" "$dir" 2>/dev/null \
      || { git clone --depth 1 "$url" "$dir"; git -C "$dir" fetch --depth 1 origin "$ref" && git -C "$dir" checkout -q FETCH_HEAD; }
  fi
}

echo "$MANIFEST" | while IFS='|' read -r name url ref; do
  [ -z "$name" ] && continue
  clone_or_update "$name" "$url" "$ref"
done

cat <<'NOTE'

Done. Still required, fetched separately (large / license-gated):
  * ARM GNU cross-toolchain 10.3-2021.07 (aarch64-none-linux-gnu):
      https://developer.arm.com/downloads/-/gnu-a  -> extract into toolchain/
  * rt86 PREEMPT_RT patch for linux-5.10 (match the vendor 5.10.176-rt86):
      https://mirrors.edge.kernel.org/pub/linux/kernel/projects/rt/5.10/
  * RKNPU2 runtime (librknnrt.so) ships inside rknn-toolkit2/rknpu2/ — no separate fetch.

Reused RE assets (go2-bsp source) come from the analysis repo, not here:
  git clone https://github.com/BonSmith0251/unitree_go2_SOM_analysis.git
  then point vendor_bsp/ at its go2-bsp/  (see docs/MIGRATION.md)
NOTE
