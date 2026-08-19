# rkport — RK3588S2 SOM porting tool

Analyze an eMMC dump (split or single), extract/rebuild partition images,
generate an RKDevTool project (`parameter.txt` + binary `config.cfg`), and patch
account passwords — with everything logged. Runs on **Ubuntu 22.04 amd64**,
fully **offline**.

```
rkport/
├─ offline_bundle/     # build once online, install on the offline VM
│  ├─ packages.list    #   top-level apt closure (deps auto-resolved)
│  ├─ collect.sh       #   RUN ONLINE (jammy/amd64): make the bundle
│  ├─ install.sh       #   RUN OFFLINE (root): local apt repo + tools + binfmt
│  └─ verify.sh        #   confirm the install is complete + functional
├─ tool/               # the porter itself
│  ├─ rkcore.py        #   Qt-free backend (real parsers/writers)
│  └─ rkport.py        #   PyQt5 GUI + headless --selftest
└─ logs/               # per-session logs
```

## Workflow

**1 · Build the bundle (online, once)** — on an Ubuntu 22.04 amd64 box with net:
```bash
cd offline_bundle && ./collect.sh
# → rkport_offline_bundle_<stamp>.tar   (debs + rk tools + guest kernel + tool)
```

**2 · Install on the offline VM** — copy the tar over, then:
```bash
tar xf rkport_offline_bundle_*.tar && cd bundle
sudo ./install.sh          # local file:// apt repo — no network touched
./verify.sh                # green/red readiness report
```

**3 · Run**
```bash
rkport                                          # GUI
rkport --selftest --dump /path/to/dump_folder   # headless smoke test
```

## Target-emulation model (amd64 host → aarch64 target)
The host is amd64; the RK3588S2 target is aarch64, emulated on top:
- **Filesystem/image work** (e2fsprogs, gdisk, dtc, config gen) is amd64-native,
  arch-agnostic, full speed.
- **Userland integrity** (Tier 2): `qemu-user-static` + `binfmt_misc` chroot —
  fast, the everyday check.
- **Full-system boot** (Tier 3): `qemu-system-aarch64` in TCG (no KVM accel on
  amd64 → slow but functional), booting a generic arm64 kernel + the rebuilt
  rootfs. Real RK3588S2 hardware remains the final word on the boot chain.

## Status
**Real tool.** All operations do real work through proven system tools
(`e2fsprogs`/`debugfs`/`mount`/`sgdisk`): carve, rebuild a truncated rootfs to a
target size (UUID+label preserved), generate `parameter.txt` + binary
`config.cfg`, and patch passwords (copy-on-write, journal/`metadata_csum`-safe,
verified). CLI (`rkport-cli`) and GUI (`rkport`) share one backend. Validated
end-to-end by `tests/selftest.sh` (9/9). See `tool/README.md` for commands and
the safety contract.
