# Source this before building:  source toolchain/env.sh
# Sets the cross-compilation environment for the RK3588S2 / Go2 target.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Target ------------------------------------------------------------
export ARCH=arm64

# Kernel / U-Boot: MUST match the vendor toolchain to avoid module ABI drift.
# ARM GNU Toolchain 10.3-2021.07 -> aarch64-none-linux-gnu-gcc 10.3.1
export CROSS_COMPILE="aarch64-none-linux-gnu-"
GNU_TC_BIN="$ROOT/toolchain/aarch64-none-linux-gnu/bin"
if [ -d "$GNU_TC_BIN" ]; then
  export PATH="$GNU_TC_BIN:$PATH"
fi

# Userspace apps (unitree_sdk2, rknpu2 runtime): focal-era aarch64 GCC is fine.
export CROSS_COMPILE_APP="aarch64-linux-gnu-"

# --- Board constants (recovered — see vendor_bsp/go2-bsp/config/board.conf) ---
export RK_SOC="rk3588s2"
export RK_KERNEL_VERSION="5.10.176-rt86+"
export RK_KERNEL_DEFCONFIG="rk3588s_go2_defconfig"
export RK_KERNEL_DTB="rk3588s-go2.dtb"           # or rk3588s-go2-cy.dtb for the CY rev
export RK_BOOTARGS="earlycon=uart8250,mmio32,0xfeb50000 console=ttyFIQ0 root=PARTUUID=614e0000-0000 rw rootwait isolcpus=3"

# FIT load addresses (from the shipped boot.img)
export RK_KERNEL_LOAD_ADDR="0x400000"
export RK_FDT_LOAD_ADDR="0x8300000"
export RK_RAMDISK_LOAD_ADDR="0xc200000"
export RK_UBOOT_LOAD_ADDR="0x200000"
export RK_ATF_BL31_LOAD_ADDR="0x40000"
export RK_OPTEE_LOAD_ADDR="0x8400000"

# --- Paths -------------------------------------------------------------
export TP="$ROOT/third_party"
# go2-bsp lives inside the analysis-repo submodule at vendor_bsp/analysis/go2-bsp
export GO2_BSP="$ROOT/vendor_bsp/analysis/go2-bsp"
export VENDOR_BSP="$GO2_BSP"   # back-compat alias
export OUT="$ROOT/bsp/out"

echo "[env] ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE  SOC=$RK_SOC  kernel=$RK_KERNEL_VERSION"
command -v ${CROSS_COMPILE}gcc >/dev/null 2>&1 \
  && echo "[env] $(${CROSS_COMPILE}gcc --version | head -1)" \
  || echo "[env] WARNING: ${CROSS_COMPILE}gcc not on PATH — install ARM GNU 10.3-2021.07 into toolchain/"
