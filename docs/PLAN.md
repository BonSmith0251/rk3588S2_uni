# RK3588S2 Development Workspace for Unitree Go2 (`rk3588S2_uni`)

## Context

**Why this project exists.** The prior effort (`unitree_go2_SOM_analysis`, at `D:\work\unitree_go2_hd`) fully *reverse-engineered* the Go2's compute module — a firmware recovery/rebuild/reflash pipeline that produced a rebuildable BSP (`go2-bsp/`), a flashable 1:1 image set (`rkdevtool_image/`), a porting tool (`rkport/`), and all Rockchip flash tooling. That work answered "how does the robot's software work and can I reproduce it."

**What's new.** This project pivots from *analysis* to *development*: a clean workspace (empty dir `C:\Users\Administrator\Documents\_work\rk3588S2_uni`) for building your own software on the RK3588S2 SOM (iFLYTEK `rk3588s-hh-navbox`) that powers the Go2. The gap it fills — none of these exist in the prior work yet: an upstream Rockchip Linux SDK tree, RKNN/NPU tooling, or Unitree SDK source.

**Intended outcome (confirmed with you).** A single integrated workspace covering four layers:
1. **Custom OS/BSP** — build your own U-Boot + kernel + rootfs, flashable via RKDevTool.
2. **Robot apps** — cross-compile `unitree_sdk2` apps talking to the Go2 over CycloneDDS.
3. **On-device AI** — `rknn-toolkit2` + RKNPU2 to run models on the RK3588's 3-core NPU.
4. **Integrated dev env** — cross-toolchain, build/flash scripts, QEMU test, all repeatable.

You have the physical Go2 to flash and test, building from the official Rockchip/Radxa SDK + your reconstructed `go2-bsp` + `unitree_sdk2`.

## Guiding principles (safety contract)

- **Reuse, don't rebuild.** `go2-bsp`, `rkdevtool_image`, `rkport`, `_porting_tools`, `tools` under `D:\work\unitree_go2_hd\` are the source of truth for everything already recovered. The new repo *references* them; it does not re-derive them.
- **The real Go2 is the last resort, never the first.** Every image is proven in QEMU and diffed against the golden dump before it touches eMMC. Maskrom recovery is rehearsed *before* the first custom flash.
- **`uni.img` and `userdata` are sacred.** `uni.img` = per-device identity (serial + keys, rollback-protected). `userdata` (partition 8) = per-robot calibration/state, never in the dump. Our scripts never write either. Keep the stock `rom/*.BIN` as the rollback master.
- **Signed boot chain constraint.** The stock chain is a signed FIT (RSA-2048/PSS: ATF + OP-TEE + U-Boot + rollback protection). A self-built U-Boot/kernel won't be accepted unless we keep the stock signed `idbloader.img`/`uboot.img` byte-exact (replace only `boot`/`rootfs`) **or** provision our own keys. Default: keep stock signed loaders; replace only boot + rootfs.

## Recommended repo structure

```
rk3588S2_uni/
  README.md                 orientation + the safety contract above
  Makefile                  umbrella targets dispatching into each layer
  third_party/              pinned upstream sources (git submodules / fetch manifest)
    rkbin/                    Rockchip rkbin: bl31, ddr, spl_loader, mkimage keys
    u-boot-rockchip/          Rockchip U-Boot, rk3588 branch
    kernel-rockchip-5.10/     Rockchip linux-5.10 BSP + rt86 PREEMPT_RT patch
    rkbuild/                  Radxa rbuild OR Rockchip buildroot/debian SDK (rootfs)
    unitree_sdk2/             unitreerobotics/unitree_sdk2 (pinned)
    unitree_ros2/             optional (CycloneDDS + unitree_go/hg msgs)
    rknn-toolkit2/            model conversion (x86 host) + rknpu2 runtime + demos
  vendor_bsp/               read-only import of go2-bsp (submodule / vendored copy)
  toolchain/                env.sh (CROSS_COMPILE/ARCH/SYSROOT), Dockerfile.build
  bsp/                      LAYER 1: uboot/ kernel/ rootfs/ pack/ out/
  apps/                     LAYER 2: cmake/ hello_lowstate/ examples/ ros2_ws/
  ai/                       LAYER 3: models/ convert/ runtime/ demos/
  flash/                    LAYER 4: loaders/ golden/ flash.sh recover.sh verify.sh
  qemu/                     user/ (qemu-user chroot)  system/ (full boot)
  scripts/                  fetch_sources.sh, env checks
  docs/                     RUNBOOK-flash.md, boot-chain.md, dds-topics.md
```

**Reused-asset import:** default to a **git submodule of a copy of `go2-bsp`** (portable across WSL/Windows) rather than a WSL symlink to `D:\`. `.gitignore` excludes `out/`, `downloads/`, `third_party/*/`, and all `*.img`.

## Phased milestones

Each phase gates the next; hardware risk is deferred as late as possible.

**Phase 0 — Workspace & toolchain (no hardware).**
Set up WSL2 Ubuntu 22.04 (matches prior work + `rkport`) and/or `toolchain/Dockerfile.build`. Install ARM GNU 10.3-2021.07 (`aarch64-none-linux-gnu-`, the exact vendor kernel toolchain). Write `scripts/fetch_sources.sh` pinning every upstream. Import `go2-bsp` into `vendor_bsp/`.
*Verify:* `make images` inside imported `go2-bsp` repacks a valid `boot.img` from the prebuilt `Image` (uses `dtc`, no kernel tree needed) — proves toolchain + host env before changing anything.

**Phase 1 — Golden baseline & recovery rehearsal (safety gate).**
Stage `flash/golden/` (SHA256SUMS of stock `rkdevtool_image/Image/*` + `go2-bsp/prebuilt/*.img`), `flash/loaders/rk3588_spl_loader_v1.19.113.bin`, `flash/recover.sh`, `docs/RUNBOOK-flash.md`.
*Verify (before ANY write):* (1) maskrom mode → `rkdeveloptool ld` sees the SOM; (2) read-back partitions (`rkdeveloptool rl`) and diff vs golden; (3) re-flash the **stock** image set 1:1 and confirm the robot still boots. This stock re-flash + boot **is** the rollback rehearsal — no custom image until it passes.

**Phase 2 — Layer 1: custom kernel hello-world.**
Fetch Rockchip linux-5.10 + rt86 patch; build with `go2-bsp/kernel/config/rk3588s_go2_defconfig` + `rk3588s-go2.dts`; repack `boot.img` via `go2-bsp/scripts/pack_images.sh` / `boot.its`. Keep stock `idbloader.img`/`uboot.img` byte-exact.
*Milestone:* self-built kernel boots to a login shell, identifiable by changed `uname -r` or an added `printk`, on the stock rootfs.
*Verify:* boot in `qemu-system-aarch64` first, then flash **boot partition only** on hardware (rootfs untouched → revert by re-flashing stock `boot.img`). Watch serial `ttyFIQ0` / `earlycon` at `0xfeb50000`.

**Phase 3 — Layer 1: custom rootfs.**
Reproduce Ubuntu 20.04 focal arm64 from `go2-bsp/rootfs/packages.list` + manifests via `make_rootfs.sh` (debootstrap + overlay + vendor blobs); or a slim Radxa rbuild image for experimentation. Keep `/unitree` blobs if you want the robot stack to run.
*Verify:* `qemu-user-static` chroot smoke test → `qemu-system-aarch64` full boot → hardware flash of `rootfs` partition only.

**Phase 4 — Layer 2: Unitree SDK "hello lowstate".**
Cross-compile `unitree_sdk2` for aarch64 (`apps/cmake` toolchain file); build `apps/hello_lowstate` subscribing to `rt/lf/lowstate` on CycloneDDS domain 0.
*Milestone:* print battery/IMU/joint state from `unitree_go::msg::dds_::LowState_`. **Read-only first — no motion commands.**
*Verify:* DDS discovery succeeds against the robot's existing `iox-roudi`/CycloneDDS; topic list matches `docs/dds-topics.md`. Only then attempt a benign `rt/api/*` request.

**Phase 5 — Layer 3: NPU "hello inference".**
On x86 host, `rknn-toolkit2` converts a stock MobileNet/YOLO `.onnx` → `.rknn` (target `rk3588`); deploy `rknpu2` runtime + demo to the rootfs.
*Milestone:* run the `.rknn` demo on the 3-core NPU; print top-1 label + inference time.
*Verify:* output matches upstream demo; NPU utilization is non-zero via `/sys/kernel/debug/rknpu/load` (confirms NPU, not CPU fallback).

**Phase 6 — Integration & repeatability.**
Umbrella `Makefile` (`make bsp|apps|ai|image|flash`); one-command reproducible build in the container; `verify.sh` gate before every flash.
*Verify:* clean checkout → single command → image proven in QEMU → guarded hardware flash.

## Cross-compilation strategy (Windows host)

- **Build in WSL2 Ubuntu 22.04** (Rockchip SDK needs Linux x86_64; near-native speed; matches `rkport`). Reproducible variant: Docker container pinning `aarch64-none-linux-gnu-gcc 10.3.1` for kernel/U-Boot (must match vendor to avoid module-loading ABI drift) + distro `aarch64-linux-gnu` for apps (focal glibc).
- **Flash from native Windows**, not WSL: `rkdeveloptool`/maskrom USB is unreliable through WSL2 (usbipd-win is flaky). Use `RKDevTool_Release` GUI with `rkdevtool_image/config.cfg`, or `rkdeveloptool.exe`. WSL2 only *builds* the images.
- **QEMU (pre-hardware gate, `rkport`'s 3-tier model):** Tier 2 `qemu-user-static` chroot for fast userland checks; Tier 3 `qemu-system-aarch64` (TCG) full boot to catch init/userspace regressions. QEMU does **not** validate the signed RK boot chain / OP-TEE — hardware remains the final word there.

## Critical files (reference, do not modify in place — import into `vendor_bsp/`)

- [board.conf](D:\work\unitree_go2_hd\go2-bsp\config\board.conf) — all recovered constants: kernel `5.10.176-rt86+`, load addrs (FDT `0x8300000`, U-Boot `0x200000`, ATF `0x40000`, OP-TEE `0x8400000`), bootargs incl. `isolcpus=3`, toolchain.
- [rk3588s_go2_defconfig](D:\work\unitree_go2_hd\go2-bsp\kernel\config\rk3588s_go2_defconfig) — exact vendor kernel `.config` for Layer 1.
- [flash.sh](D:\work\unitree_go2_hd\go2-bsp\scripts\flash.sh) — safety-critical flashing logic to wrap (LBAs uboot=16384/boot=36864/rootfs=495616; already refuses `userdata`; add an explicit `uni.img` guard).
- [parameter.txt](D:\work\unitree_go2_hd\rkdevtool_image\parameter.txt) — GPT/partition + firmware-version baseline (`FIRMWARE_VER 1.1.15`, `RK3588S`).
- [rkport README](D:\work\unitree_go2_hd\rkport\README.md) — QEMU 3-tier pre-hardware model + offline build workflow.

## Open decisions (resolve during Phase 0–1, not blocking to start)

- **GPT/firmware baseline:** `go2-bsp` `parameter.txt` (1.0 / RK3588) vs `rkdevtool_image` (1.1.15 / RK3588S). Pick one authoritative GPT; never `--repartition` on the real robot until resolved.
- **Boot chain:** keep stock signed loaders (safe, limits U-Boot/kernel freedom) vs provision own keys (full control, higher brick risk). Default: keep stock.
- **Rootfs:** faithful focal rebuild (keeps `/unitree` working) vs slim Radxa/Debian (clean dev, loses robot stack).
- **Keep or drop** the proprietary `/unitree` `master_service` stack in custom images (it's Virbox-virtualized + FMX-encrypted — carried as prebuilt blobs, not rebuildable from source).
- **unitree_ros2** in scope now, or SDK2-only first.
- **First NPU model:** classification (MobileNet) vs detection (YOLO).

## Verification (end-to-end)

The safety-gated hardware path *is* the verification story:
1. **Toolchain proof (Phase 0):** `make images` in imported `go2-bsp` reproduces a valid `boot.img`.
2. **Recovery proof (Phase 1):** maskrom read-back diffs clean vs golden; stock 1:1 re-flash boots the robot.
3. **Per-layer hello-world:** custom kernel boots (changed `uname -r`); `hello_lowstate` prints live `LowState_`; `.rknn` demo runs on NPU with non-zero `/sys/kernel/debug/rknpu/load`.
4. **Every flash** is preceded by a QEMU boot (Tier 2 + Tier 3) and a `flash/verify.sh` size/partition/SHA gate; only boot/rootfs partitions are ever written; stock image kept as rollback.
