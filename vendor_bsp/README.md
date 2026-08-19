# vendor_bsp/ — reused BSP import (git submodule)

The reconstructed **go2-bsp** is imported here as a git submodule of the analysis
repo, so it is *reused, not re-derived*:

```
vendor_bsp/analysis/            <- submodule: BonSmith0251/unitree_go2_SOM_analysis
vendor_bsp/analysis/go2-bsp/    <- the BSP the build scripts reference (GO2_BSP)
```

Scripts and the Makefile reference `GO2_BSP = vendor_bsp/analysis/go2-bsp`.

## After cloning rk3588S2_uni on a new machine

```bash
git submodule update --init --depth 1 vendor_bsp/analysis    # or: make submodules
```

## What the submodule contains

- **Source (in git):** `config/board.conf`, `config/parameter.txt`,
  `kernel/config/rk3588s_go2_defconfig`, `kernel/dts/*.dts`, `kernel/fit/boot.its`,
  `u-boot/{dts,fit}/*`, `rootfs/packages.list`, `scripts/*.sh`, `Makefile`.
- **Prebuilt blobs (NOT in git — transfer out-of-band):** `kernel/prebuilt/`
  (`Image`, `resource.img`, ramdisks), `u-boot/prebuilt/` (`bl31-*.bin`, `tee.bin`,
  `u-boot-nodtb.bin`). These are gitignored in the analysis repo. Copy them from
  `D:\work\unitree_go2_hd\go2-bsp\**\prebuilt\` — see docs/MIGRATION.md.

`make images` (Phase-0 gate) repacks a valid `boot.img` from the prebuilt `Image`
using `dtc` — no kernel source needed — proving the toolchain. It needs the prebuilt
blobs above, so stage them first.
