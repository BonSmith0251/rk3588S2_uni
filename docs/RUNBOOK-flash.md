# RUNBOOK — flashing the RK3588S2 Go2 SOM (safety-gated)

Run this on the **flashing machine** next to the robot — not the build PC. Every
step here assumes you have the golden rollback set staged (`flash/golden/`) and the
SPL loader (`flash/loaders/rk3588_spl_loader_v1.19.113.bin`).

**Golden rule:** you do not flash a custom image until you have proven, on this exact
robot, that you can restore it from maskrom. The stock re-flash below IS that proof.

## 0. Prerequisites

- Rockchip USB driver installed (`_porting_tools/DriverAssistant_v5.14`).
- `rkdeveloptool` (or `RKDevTool_Release` GUI) available.
- Golden stock set present: `idbloader.img`, `uboot.img`, `boot.img`, `recovery.img`,
  `rootfs.img`, `gpt.img` (from `rkdevtool_image/Image/`) + `SHA256SUMS`.
- Serial console on `ttyFIQ0` @ **1.5 Mbaud** wired up (the real diagnostic channel).
- The original `rom/*.BIN` 4-part dump archived somewhere safe as the ultimate backup.

## 1. Enter maskrom & confirm detection

Put the SOM in maskrom mode, then:
```bash
rkdeveloptool ld          # expect a line containing "Maskrom"
```
If nothing shows: reseat USB, check the driver, retry the maskrom entry.

## 2. Read-back proof (no writes yet)

Confirm you can pull data off the device before you ever push:
```bash
rkdeveloptool db flash/loaders/rk3588_spl_loader_v1.19.113.bin
rkdeveloptool rl 0x9000 0x20000 boot_readback.img     # read the boot partition
sha256sum boot_readback.img
```
This proves the link works both ways.

## 3. Rollback rehearsal — re-flash STOCK 1:1

Restore the stock set and confirm the robot boots normally:
```bash
RK_GOLDEN_DIR=flash/golden ./flash/recover.sh
```
Watch the serial console to a login prompt. **Only after a clean stock boot do you
proceed to any custom image.** If this fails, stop — do not flash custom images.

## 4. Flash a custom image (boot-only first)

Custom kernel goes to the `boot` partition only; rootfs untouched → trivially
reverted by re-flashing stock `boot.img`.
```bash
# on the build PC: make image  -> copy bsp/out/boot.img (+ SHA256SUMS) here
RK_ALLOW_FLASH=1 ./flash/flash.sh boot
```
`flash.sh` runs `verify.sh` first and refuses `uni`/`userdata`. Boot, check
`uname -r` on the serial console. Revert = `recover.sh` or re-flash stock `boot.img`.

## 5. Custom rootfs (later phase)

Only after the custom kernel is proven. Flash `rootfs` partition only; keep stock
boot chain byte-exact. Keep `/unitree` blobs if you want the robot stack to run.

## Never do

- Never write `uni.img` (per-device identity) or `userdata` (per-robot calibration).
- Never `--repartition` / rewrite the GPT on the real robot until the GPT/firmware
  baseline question (1.0/RK3588 vs 1.1.15/RK3588S) is settled — see docs/PLAN.md.
- Never substitute an unsigned bootloader for the stock signed FIT unless you have
  provisioned your own keys and understand the rollback-fuse implications.

## If it won't boot

1. Re-enter maskrom (it survives a bad rootfs/boot — it's in ROM).
2. `./flash/recover.sh` to restore stock.
3. If maskrom itself is unreachable, fall back to the full `rom/*.BIN` restore via
   RKDevTool "Download Image" using `rkdevtool_image/config.cfg`.
