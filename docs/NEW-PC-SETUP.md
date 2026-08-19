# New-PC setup — fastest path from bare Windows to developing

Goal: on a fresh Windows PC, clone the repos, regenerate the derived source
projects (`extracted/`, `rkdevtool_image/`, `extracted_decrypted/`) from the eMMC
dump, then start building the new RK3588S2 robot project on top. **All build steps
run inside WSL2 Ubuntu, never cmd/PowerShell** (see [WSL-SETUP.md](WSL-SETUP.md)).

Time budget: WSL+deps ~15 min · asset regen ~20 min (mostly unattended) · bootstrap ~5 min.

## 0. One-time host prep (PowerShell → then WSL)

```powershell
wsl --install -d Ubuntu-22.04         # reboot if asked, then open "Ubuntu 22.04"
```
Inside WSL, install deps + confirm network/creds ([WSL-SETUP.md §0](WSL-SETUP.md)):
```bash
sudo apt update && sudo apt install -y build-essential bc bison flex libssl-dev \
  device-tree-compiler u-boot-tools e2fsprogs gdisk parted kpartx debootstrap \
  qemu-user-static qemu-system-arm binfmt-support python3 rsync file cmake \
  gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
```

## 1. Clone both repos (inside WSL home — NOT /mnt/c)

```bash
cd ~
git clone https://github.com/BonSmith0251/unitree_go2_SOM_analysis.git   # analysis + tools + rev/
git clone https://github.com/BonSmith0251/rk3588S2_uni.git               # the dev project
```

## 2. Regenerate the derived projects from the dump

Download the 4 dump parts from your Google Drive into the analysis repo's `rom/`:
```
~/unitree_go2_SOM_analysis/rom/A_rk3588S2_dog_bin.BIN   (…B, C, D)
```
For the full decrypted-config swap, first drop in the 39 KB `rev/` tree from your
migration bundle (adds the 22 FMX plaintexts that aren't in git):
```bash
cp -r /mnt/c/path/to/_MIGRATION/rev ~/unitree_go2_SOM_analysis/
```
Then one command regenerates all three (run_all.sh + rkport, in parallel, ~20 min):
```bash
cd ~/unitree_go2_SOM_analysis
bash prepare_assets.sh
```
Produces (all gitignored, local):
- `extracted/` — partitions, rootfs, 114k-row manifest, **and `go2-bsp/` with prebuilt blobs** (`--with-bsp` is on by default, so you get the kernel `Image`/ramdisks/bl31/tee too).
- `rkdevtool_image/` — flashable 1:1 RKDevTool project (rebuilt `rootfs.img`).
- `extracted_decrypted/` — `extracted/rootfs` with the **10 de-VirBox'd binaries** swapped in.

**On the decrypted configs:** the 10 decrypted *binaries* are committed in `rev/` and
swap in automatically. The 22 FMX *config* plaintexts are **not** committed — if you
did the `cp -r .../rev` step above they swap in too; otherwise the script skips them
(and you can regenerate the 10 `cmd/` scripts with `python3 tools/fmx.py`). The
binaries are the substance; configs are optional.

## 3. Bring up the dev project

```bash
cd ~/rk3588S2_uni
./bootstrap.sh --bundle ~/unitree_go2_SOM_analysis   # submodule + env + Phase-0 gate
```
The submodule already carries `go2-bsp`; if you skip the migration bundle, the
prebuilt blobs you just regenerated live at
`~/unitree_go2_SOM_analysis/go2-bsp/**/prebuilt/` — point `--bundle` there or copy
them into `vendor_bsp/analysis/go2-bsp/`. Then `make images` proves the toolchain.

## 4. Develop from here

You now have, side by side: the reconstructed BSP + regenerated OS image, the
decrypted robot binaries for reference, and the `rk3588S2_uni` scaffold. Follow
[PLAN.md](PLAN.md) — Phase 2 (custom kernel) onward — building the new robot stack
on top of these regenerated sources.

## What you did NOT have to migrate

Only the 4 dump files (already on your Drive) + the two git repos. Everything
else — `extracted/` (21 GB), `rkdevtool_image/` (8 GB), `extracted_decrypted/`
(6 GB), `flash/` (31 GB) — is regenerated here, never uploaded.
