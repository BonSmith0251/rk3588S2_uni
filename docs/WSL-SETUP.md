# WSL2 setup — the build environment for this project

The `.sh` scripts and all BSP builds are Linux/bash and need Linux tools
(`debootstrap`, `dtc`, `mkimage`, the aarch64 cross-compiler, `qemu`). On Windows
they run inside **WSL2 Ubuntu 22.04**, not in PowerShell/cmd. Git Bash can run the
*git* commands but lacks the build toolchain — use WSL2 for anything past `git`.

## 1. Install WSL2 + Ubuntu 22.04

In an **Administrator PowerShell**:
```powershell
wsl --install -d Ubuntu-22.04
```
Reboot if prompted, then launch **Ubuntu 22.04** from the Start menu and create your
Linux user. Confirm it's WSL**2** (not 1):
```powershell
wsl -l -v      # VERSION column should read 2
```

## 2. Install build dependencies (inside Ubuntu)

```bash
sudo apt update && sudo apt install -y \
  build-essential bc bison flex libssl-dev libncurses-dev \
  device-tree-compiler u-boot-tools \
  e2fsprogs dosfstools debootstrap \
  qemu-user-static qemu-system-arm binfmt-support \
  python3 python3-pip git rsync file cpio kmod
```

## 3. Install the vendor cross-toolchain (kernel / U-Boot)

Kernel and U-Boot **must** use `aarch64-none-linux-gnu-gcc 10.3.1`
(ARM GNU Toolchain 10.3-2021.07) to match the vendor ABI. Either let
`scripts/fetch_sources.sh` note it, or install manually:
```bash
cd ~/rk3588S2_uni/toolchain
wget https://developer.arm.com/-/media/Files/downloads/gnu-a/10.3-2021.07/binrel/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu.tar.xz
tar xf gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu.tar.xz
mv gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu aarch64-none-linux-gnu
# toolchain/env.sh adds toolchain/aarch64-none-linux-gnu/bin to PATH automatically
```
For userspace apps, the distro toolchain is fine: `sudo apt install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu cmake`.

## 4. Clone the repo INSIDE the WSL filesystem

Do **not** build from `/mnt/c/...` or `/mnt/d/...` — cross-filesystem I/O in WSL is
very slow. Clone into the Linux home instead:
```bash
cd ~
git clone https://github.com/BonSmith0251/rk3588S2_uni.git
cd rk3588S2_uni
make submodules          # pulls go2-bsp source
```
Then drop the migration bundle's prebuilt blobs in (see docs/MIGRATION.md), and:
```bash
./scripts/check_env.sh   # tells you exactly what's still missing
source toolchain/env.sh
make images              # Phase-0 gate: repacks a valid boot.img
```

## Notes

- **Line endings:** `.gitattributes` forces LF, so scripts are Unix-formatted on
  checkout — no `\r` breakage. If you ever hit `bad interpreter: ^M`, run
  `sed -i 's/\r$//' <file>`.
- **Reaching Windows files:** your drives are under `/mnt/c`, `/mnt/d` — handy for
  copying the migration bundle in, but don't *build* there.
- **USB / flashing:** WSL2 USB passthrough to maskrom is unreliable. This box builds
  only; flashing happens on the separate machine (see docs/RUNBOOK-flash.md).
- **Docker alternative:** `toolchain/Dockerfile.build` (Ubuntu 22.04) is the
  reproducible/CI path if you prefer a container over WSL.
