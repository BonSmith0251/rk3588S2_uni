# vendor_bsp/ — reused BSP import

This directory holds the **reconstructed go2-bsp** from the analysis project. It is
*reused, not re-derived*. Import it one of two ways:

**Submodule (preferred, portable):**
```bash
git submodule add https://github.com/BonSmith0251/unitree_go2_SOM_analysis.git _analysis
ln -s _analysis/go2-bsp/* .        # or copy the go2-bsp/ contents here
```

**Copy:**
```bash
cp -r /path/to/unitree_go2_hd/go2-bsp/* vendor_bsp/
```

## What must be present

- **Source (from git):** `config/board.conf`, `config/parameter.txt`,
  `kernel/config/rk3588s_go2_defconfig`, `kernel/dts/*.dts`, `kernel/fit/boot.its`,
  `u-boot/{dts,fit}/*`, `rootfs/packages.list`, `scripts/*.sh`, `Makefile`.
- **Prebuilt blobs (NOT in git — transfer out-of-band):** `kernel/prebuilt/`
  (`Image`, `resource.img`, ramdisks), `u-boot/prebuilt/` (`bl31-*.bin`, `tee.bin`,
  `u-boot-nodtb.bin`). Needed for `make images` and FIT packing. See docs/MIGRATION.md.

`make -C vendor_bsp images` is the Phase-0 gate: it repacks a valid `boot.img` from
the prebuilt `Image` using `dtc` — no kernel source needed — proving the toolchain.
