# rkport tool

Real RK3588S2 SOM porter. Operations shell out to proven tools
(`e2fsprogs` / `debugfs` / `mount` / `sgdisk`) — nothing reimplements a
filesystem. Every op is logged with its exact command line, mutations are
**copy-on-write**, and results are verified.

## Files
- `rkcore.py` — no-root analysis + writers: split-dump virtual device, GPT
  parse, ext4 capture-completeness check, `parameter.txt` + binary `config.cfg`.
- `rkops.py` — **real** privileged operations (carve, rebuild rootfs, patch
  shadow, verify, chroot-test). Root required for rebuild/patch/chroot.
- `rkport_cli.py` — scriptable CLI (the workhorse; fully tested).
- `rkport.py` — PyQt5 GUI wired to the same ops, with a dry-run toggle
  (default ON) and confirm-before-write.

## CLI
```bash
# analysis (no root)
rkport-cli analyze  --dump /path/to/dump_dir

# full RKDevTool project: carve raw partitions, rebuild a truncated rootfs to a
# target size (UUID+label preserved), write parameter.txt + config.cfg, verify
sudo rkport-cli project --dump DUMP --out PROJ --target-gib 8 [--sanitize]

# single partition
sudo rkport-cli extract        --dump DUMP --name boot --out boot.img
sudo rkport-cli rebuild-rootfs --dump DUMP --out rootfs.img --target-gib 8

# list every account (uid/shell/password status) — no root, reads via debugfs
rkport-cli list-users --image rootfs.img [--login-only]

# passwords — copy-on-write, verified, journal/csum-safe (loop mount)
# --accounts takes a comma list or 'all' (every account in shadow)
sudo rkport-cli patch      --image rootfs.img --accounts root,unitree --password PW
sudo rkport-cli patch-dump --dump DUMP --out rootfs_patched.img --accounts root --password PW

sudo rkport-cli verify      --dir PROJ/Image
sudo rkport-cli chroot-test --image rootfs.img       # Tier-2 aarch64 userland test
```
Add `--dry-run` (global) to preview any command without writing.

## GUI
```bash
rkport            # analysis/config as any user
sudo rkport       # to arm extract / rebuild / patch
```
Untick "Dry run" and confirm to perform real writes.

## Safety contract (enforced in code)
- Source dump `.BIN` files are **never** mutated. `patch-dump` carves a
  copy-on-write working image and emits a new file.
- `patch` copies the image first (`--reflink=auto`), edits the copy.
- Shadow edits go through a **loop mount** so the kernel keeps the journal and
  `metadata_csum` correct — never raw byte-splicing. `e2fsck -fy` replays the
  journal before editing; a final `e2fsck -fn` verifies.
- rootfs rebuild preserves the original label + UUID (so `root=PARTUUID=…`
  still resolves) and re-runs `e2fsck` on the output.

## Regression test
`sudo ../tests/selftest.sh` builds a tiny GPT+ext4 fixture and exercises every
real operation (9 checks: analyze, carve, rebuild w/ UUID, content, patch CoW,
original-untouched, patch-dump, verify). Must print `REAL BACKEND OK`.
