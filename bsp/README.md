# bsp/ — Layer 1: custom OS build

Build your own U-Boot + kernel + rootfs for the RK3588S2, then pack a flashable
image set. Reuses `vendor_bsp/` (exact defconfig, DTS, FIT layout, packages.list).

- `kernel/` — build a custom `Image` + DTBs from Rockchip linux-5.10 + rt86, using
  `vendor_bsp/kernel/config/rk3588s_go2_defconfig`. First milestone: a self-built
  kernel that boots to a shell (changed `uname -r`). Boot partition only.
- `rootfs/` — reproduce Ubuntu 20.04 focal arm64 via debootstrap from
  `vendor_bsp/rootfs/packages.list` + overlay + `/unitree` vendor blobs.
- `uboot/` — normally keep the stock signed `uboot.img`/`idbloader.img` byte-exact;
  only touched if you provision your own keys.
- `pack/` — assemble `boot.img` (FIT) and the flashable set into `out/`.

See docs/PLAN.md (Phases 2–3) and docs/boot-chain.md for constraints. All builds run
in WSL2; nothing here flashes — that happens on the separate flashing machine.
