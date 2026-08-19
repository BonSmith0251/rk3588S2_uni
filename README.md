# rk3588S2_uni — Unitree Go2 / RK3588S2 development workspace

A development workspace for building software on the **RK3588S2 SOM** (iFLYTEK
`rk3588s-hh-navbox`) that powers the **Unitree Go2**. It spans four layers:

1. **OS / BSP** (`bsp/`) — build your own U-Boot + kernel + rootfs, flashable via RKDevTool.
2. **Robot apps** (`apps/`) — cross-compile `unitree_sdk2` apps talking to the Go2 over CycloneDDS.
3. **On-device AI** (`ai/`) — `rknn-toolkit2` + RKNPU2 to run models on the RK3588's 3-core NPU.
4. **Integrated dev env** — cross-toolchain, build/flash scripts, QEMU test (`toolchain/`, `flash/`, `qemu/`).

This project *reuses* — does not re-derive — the reverse-engineering output at
`unitree_go2_SOM_analysis` (`go2-bsp/`, `rkdevtool_image/`, `rkport/`, `tools/`).
See `docs/` for the full plan, migration, and flashing runbook.

## Safety contract (read before flashing)

- **The real Go2 is the last resort, never the first.** Every image is proven in
  QEMU and diffed against the golden dump before it touches eMMC. Rehearse maskrom
  recovery *before* the first custom flash.
- **`uni.img` and `userdata` are sacred.** `uni.img` = per-device identity (serial +
  keys, rollback-protected). `userdata` = per-robot calibration, never in the dump.
  Our scripts never write either. Keep the stock `rom/*.BIN` as the rollback master.
- **Signed boot chain.** Stock boot is a signed FIT (RSA-2048/PSS: ATF + OP-TEE +
  U-Boot + rollback). Default: keep stock `idbloader.img`/`uboot.img` byte-exact and
  replace only `boot`/`rootfs`. Provisioning your own keys is opt-in and higher risk.

## Layout

```
third_party/   pinned upstream sources (fetched, gitignored)
vendor_bsp/    read-only import of go2-bsp (reused RE assets)
toolchain/     cross toolchains + env.sh + build container
bsp/           LAYER 1: uboot/ kernel/ rootfs/ pack/
apps/          LAYER 2: cmake/ hello_lowstate/ examples/ ros2_ws/
ai/            LAYER 3: models/ convert/ runtime/ demos/
flash/         LAYER 4: guarded flash.sh, recover.sh, verify.sh, golden/, loaders/
               + ssh_patch/ (enable SSH on the robot — see docs/SSH-PATCH.md)
qemu/          pre-hardware test: user/ (chroot)  system/ (full boot)
tools/         rkport/ — offline porting / image-rebuild tool (regen flashable img)
scripts/       fetch_sources.sh + env checks
docs/          PLAN, MIGRATION, WSL-SETUP, RUNBOOK-flash, SSH-PATCH, boot-chain, dds-topics
```

## Getting started

> **Run everything below inside WSL2 Ubuntu — NOT cmd.exe or PowerShell.**
> `make`, `cp`, `source`, and `./*.sh` are Linux commands; in cmd you'll get
> `'make' is not recognized`. First-time WSL install + deps: **[docs/WSL-SETUP.md](docs/WSL-SETUP.md)**.
> Open the Linux shell with `wsl` (or launch "Ubuntu 22.04" from the Start menu),
> then clone the repo *inside* WSL (`cd ~ && git clone …`) for much faster builds —
> don't build from `/mnt/c/...`.

```bash
# 1. pull the reused go2-bsp (submodule) + pinned upstreams
make submodules                 # = git submodule update --init vendor_bsp/analysis
./scripts/fetch_sources.sh      # pull pinned upstreams into third_party/

# 2. one-time host setup (WSL2 Ubuntu 22.04) + environment
./scripts/check_env.sh          # verify toolchain + deps + submodule
source toolchain/env.sh

# 3. Phase 0 gate — prove the toolchain reproduces a valid boot.img
#    (needs the prebuilt blobs staged into vendor_bsp/analysis/go2-bsp — see docs/MIGRATION.md)
make images
```

New machine? See **[docs/WSL-SETUP.md](docs/WSL-SETUP.md)** (build env) and
**[docs/MIGRATION.md](docs/MIGRATION.md)** (moving data). Full roadmap:
**[docs/PLAN.md](docs/PLAN.md)**. Other docs: [boot-chain](docs/boot-chain.md),
[dds-topics](docs/dds-topics.md), [RUNBOOK-flash](docs/RUNBOOK-flash.md),
[SSH-PATCH](docs/SSH-PATCH.md).

## Roles

This checkout is configured **build-only**: `flash/flash.sh` refuses to run unless
`RK_ALLOW_FLASH=1`. Flashing happens on a separate machine next to the robot — copy
built images + the golden rollback set there (see MIGRATION.md).
