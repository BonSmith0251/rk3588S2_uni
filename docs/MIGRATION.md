# Migrating this project to another machine

Your setup: **build on another Windows PC** (WSL2 for builds), and **flash from a
separate machine** physically next to the Go2. So there are two destinations with
very different needs. Nothing here is bound to your current PC — the design already
assumes builds run on Linux (WSL2) and flashing runs elsewhere.

---

## The three tiers of data

| Tier | What | Size | How it moves |
|---|---|---|---|
| **A. Source/scripts** | `rk3588S2_uni` repo, `go2-bsp/` *source*, `tools/`, `rkport/` | MBs | **git** |
| **B. Build-input blobs** | `go2-bsp/**/prebuilt/` (Image, resource.img, ramdisks, bl31, tee.bin) | ~100–200 MB | out-of-band → **build PC** |
| **C. Flash artifacts + rollback** | `rkdevtool_image/`, golden `rom/*.BIN`, `_porting_tools/` | ~24 GB | out-of-band → **flashing machine** |

Tier B is gitignored (`**/prebuilt/`) but the build needs it. Tier C is huge and
per-device — it belongs on the flashing machine, not the build PC.

---

## On the new Windows **build** PC

1. **Install WSL2 Ubuntu 22.04** and build deps:
   ```powershell
   wsl --install -d Ubuntu-22.04
   ```
   Then inside WSL: `sudo apt update && sudo apt install -y build-essential bc bison flex libssl-dev device-tree-compiler u-boot-tools e2fsprogs debootstrap qemu-user-static qemu-system-arm binfmt-support python3 git rsync`

2. **Install the exact vendor cross-toolchain** — ARM GNU Toolchain 10.3-2021.07
   (`aarch64-none-linux-gnu-gcc 10.3.1`). `scripts/fetch_sources.sh` pulls it, or
   download from ARM's developer site. Kernel/U-Boot must use this to avoid
   module-loading ABI drift against the RT kernel.

3. **Get Tier A (source)** — do this **inside the WSL Ubuntu shell** (run `wsl`
   first), in your Linux home, not in cmd.exe and not under `/mnt/c`:
   ```bash
   cd ~
   git clone https://github.com/BonSmith0251/rk3588S2_uni.git
   cd rk3588S2_uni
   make submodules      # pulls go2-bsp source via vendor_bsp/analysis submodule
   ```
   The reused go2-bsp source arrives automatically through the submodule at
   `vendor_bsp/analysis/go2-bsp` — no separate clone needed.

4. **Get Tier B (prebuilt blobs)** — these are NOT in git (gitignored in the
   analysis repo, so the submodule omits them). Copy `go2-bsp/**/prebuilt/` from the
   old machine into `vendor_bsp/analysis/go2-bsp/` via external drive, network share,
   or `scp`/`rsync`. Verify with the SHA256SUMS staged in `flash/golden/`.

5. **Fetch fresh upstreams (never migrate these):**
   ```bash
   ./scripts/fetch_sources.sh    # Rockchip kernel/u-boot/rkbin, unitree_sdk2, rknn-toolkit2
   ```

6. **Prove the environment** (Phase 0 gate): `make images` inside the imported
   `go2-bsp` must repack a valid `boot.img` from the prebuilt `Image`. If that
   works, the toolchain + host env are good before you change anything.

**Flashing is disabled on this box by design** — WSL2 USB passthrough to maskrom is
unreliable, and this machine isn't next to the robot. `flash/flash.sh` will refuse
to run unless `RK_ALLOW_FLASH=1` is set.

---

## On the **flashing** machine (next to the Go2)

Only built images + the rollback set need to reach it.

1. **Rollback master (do this first):** copy the golden stock set — either
   `rkdevtool_image/` (1:1 flashable clone) or the original `rom/*.BIN` (4 parts).
   Without this you cannot recover a bad flash. Verify SHA256 after transfer.
2. **Flash tooling:** copy `_porting_tools/` — `RKDevTool_Release`,
   `DriverAssistant_v5.14` (install the Rockchip USB driver), `rkdeveloptool`,
   `rk3588_spl_loader_v1.19.113.bin`.
3. **Built images:** transfer `boot.img` / `rootfs.img` produced on the build PC
   (plus their SHA256SUMS) whenever you have a new build to flash.
4. **Rehearse recovery before any custom flash** — see `docs/RUNBOOK-flash.md`
   (maskrom read-back + stock 1:1 re-flash = the rollback rehearsal).

---

## What NOT to migrate

- **SDK sources & toolchains** — refetched by `fetch_sources.sh`, always fresh & pinned.
- **`extracted/`** (22 GB) — regenerable from the dump; not needed to develop.
- **`__pycache__/`, logs, `*.tmp`** — noise.
- **Per-device secrets** — `hashcat/`, `crack_kit/hash.txt`, `uni.img`, `full.img`,
  the DDS private key, WiFi creds. These are per-robot and stay off shared machines
  and off git (already gitignored). Move them deliberately, encrypted, only if a
  specific task needs them.

---

## Quick transfer recipes

**External drive (simplest for Tier B/C):** copy the folders, then verify:
```bash
sha256sum -c flash/golden/SHA256SUMS
```

**Network (rsync over SSH), build-PC Tier B example:**
```bash
rsync -av --progress old-pc:/d/work/unitree_go2_hd/go2-bsp/ ./vendor_bsp/
```

**Git for Tier A** is the durable path — push `rk3588S2_uni` to a remote so any
machine can `git clone` it and re-fetch everything else.
