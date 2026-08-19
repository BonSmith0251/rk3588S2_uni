# Enabling SSH on the Go2 (RK3588S)

The stock firmware ships a module, **`unitree_patch`**, whose install hook actively
kills and disables SSH:

```
pkill -9 sshd; service ssh stop; systemctl disable ssh
```

So just setting a password is **not** enough — `sshd` gets killed and disabled on
boot. Two scripts solve this. They live in the migration bundle at
`flashing_pc/ssh_patch/` (and in the analysis repo under `_porting_tools/ssh_patch/`).

- **`go2_ssh_patch.sh`** — the full tool: live robot, mounted rootfs, **or** an image
  file (auto-mounts eMMC/GPT dumps and bare `rootfs.img`). Verifies the password hash,
  supports `root`, `--permit-root`, and a `--password-only` mode.
- **`ssh_persist_patch.sh`** — a simpler `ROOT=`-based variant of the same idea.

Both are `#!/bin/sh`, idempotent, and back up every file they edit (`.bak`).

## What the patch does

1. Sets the `unitree` (and optionally `root`) account password — hashed with
   `openssl passwd -6` (sha512crypt) and **verified** after writing `/etc/shadow`.
2. **Neutralizes** the `pkill -9 sshd; …` line in
   `/unitree/robot/pkg/module/unitree_patch/module.json` (replaces it with `true`).
3. Ensures `/run/sshd` exists at boot (`/etc/tmpfiles.d/sshd.conf`).
4. Installs an **independent, self-healing** systemd unit **`sshkeep.service`**:
   runs its own `sshd -D`, `Restart=always`. It's deliberately named `sshkeep`, not
   `ssh`, so the firmware's `systemctl disable ssh` / `service ssh stop` can't touch
   it; if a `pkill -9 sshd` ever fires, systemd relaunches it within 5 s.
5. On a live system, activates it immediately and checks that port 22 is listening.

## Usage

**Offline against an image (safest — patch, then flash):** run as root in WSL2.
```bash
# a bare RKDevTool rootfs.img (plain ext4)
sudo sh go2_ssh_patch.sh --image rootfs.img --password 'NEWPASS'

# a full eMMC dump with GPT (finds & mounts the rootfs partition itself)
#   4-part dump? concatenate first:
cat A_*.BIN B_*.BIN C_*.BIN D_*.BIN > emmc_full.img
sudo sh go2_ssh_patch.sh --image emmc_full.img --password 'NEWPASS'
```
Then flash the patched image back (whole disk, or just the rootfs partition) with
`rkdeveloptool` / RKDevTool — see docs/RUNBOOK-flash.md.

**Against an already-mounted rootfs:**
```bash
sudo sh go2_ssh_patch.sh --root /mnt/goimg --password 'NEWPASS'
# or the simple variant:
ROOT=/mnt/goimg sh ssh_persist_patch.sh 'NEWPASS'
```

**On the live robot** (root shell via serial console / `init=/bin/sh`):
```bash
sh go2_ssh_patch.sh --password 'NEWPASS'
```

Useful options (`go2_ssh_patch.sh`): `--user NAME` (default `unitree`),
`--root-password PASS`, `--permit-root`, `--password-only`.

## Connecting

Wired (Ethernet), robot at `192.168.123.161`:
```bash
ssh unitree@192.168.123.161
```
`root` over SSH is key-only by default unless you pass `--permit-root`.

## Safety notes

- **Requires openssl** for hashing (present on the robot and in WSL).
- Editing an **image** needs root (`losetup` + `mount`); the script mounts, patches,
  and unmounts, cleaning up its loop device on exit.
- Every edited file is backed up with `.bak` — the change is reversible.
- This modifies the **rootfs only** (not the signed boot chain), so it stays within
  the "rootfs is rw, editable, not dm-verity" property. It never touches `uni` or
  `userdata`.
- Patching an image is preferred over live edits: you keep the original, verify
  offline, and flash a known-good result.
