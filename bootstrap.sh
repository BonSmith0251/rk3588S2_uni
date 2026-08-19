#!/usr/bin/env bash
# bootstrap.sh — one-command setup for the rk3588S2_uni workspace.
#
# RUN THIS INSIDE WSL2 Ubuntu (or any Linux x86_64 host) — NOT cmd.exe/PowerShell.
# It: inits the go2-bsp submodule, optionally installs build deps, optionally
# stages the migration bundle's prebuilt blobs, checks the environment, and runs
# the Phase-0 `make images` gate if everything needed is present.
#
# Usage:
#   ./bootstrap.sh [--install-deps] [--bundle DIR] [--fetch] [--no-images]
#
#   --install-deps   apt-get install the build toolchain + deps (uses sudo)
#   --bundle DIR     stage go2-bsp prebuilt blobs from DIR. DIR may be a
#                    regenerated analysis repo (has go2-bsp/), the go2-bsp dir
#                    itself, or an old _MIGRATION/build_pc layout. e.g.
#                    --bundle ~/unitree_go2_SOM_analysis   (after prepare_assets.sh)
#   --fetch          also run scripts/fetch_sources.sh (pull pinned upstreams)
#   --no-images      skip the final `make images` gate
#   -h | --help
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

BUNDLE="" ; INSTALL_DEPS=0 ; FETCH=0 ; DO_IMAGES=1
say(){ echo "[bootstrap] $*"; }
die(){ echo "[bootstrap] ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --install-deps) INSTALL_DEPS=1; shift;;
    --bundle) BUNDLE="${2:?path required}"; shift 2;;
    --fetch) FETCH=1; shift;;
    --no-images) DO_IMAGES=0; shift;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) die "unknown option: $1 (try --help)";;
  esac
done

# --- sanity ------------------------------------------------------------------
[ -n "${BASH_VERSION:-}" ] || die "run with bash, inside WSL2/Linux (not cmd.exe)"
case "$ROOT" in
  /mnt/*) say "WARNING: building under $ROOT (Windows filesystem) is slow — consider cloning into ~ instead.";;
esac

# --- 1. build deps (optional) ------------------------------------------------
if [ "$INSTALL_DEPS" = 1 ]; then
  say "installing build dependencies (sudo apt-get)..."
  sudo apt-get update
  sudo apt-get install -y \
    build-essential bc bison flex libssl-dev libncurses-dev \
    device-tree-compiler u-boot-tools e2fsprogs dosfstools debootstrap \
    qemu-user-static qemu-system-arm binfmt-support \
    python3 python3-pip git rsync file cpio kmod \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu cmake
fi

# --- 2. submodule (git directly, so it works before `make` exists) -----------
say "initializing go2-bsp submodule (vendor_bsp/analysis @ docs/firmware-writeups)..."
git submodule sync vendor_bsp/analysis >/dev/null 2>&1 || true
git submodule update --init --depth 1 vendor_bsp/analysis \
  || git submodule update --init vendor_bsp/analysis
[ -f vendor_bsp/analysis/go2-bsp/config/board.conf ] \
  && say "  submodule OK (go2-bsp present)" \
  || die "submodule missing go2-bsp — check network / access to the analysis repo"
# submodule scripts may be stored non-executable (Windows git); make them runnable
find vendor_bsp/analysis -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

# --- 3. stage prebuilt blobs from a migration bundle (optional) --------------
if [ -n "$BUNDLE" ]; then
  # Find a go2-bsp-shaped dir with kernel/prebuilt (regenerated go2-bsp, its parent, or old layout)
  src=""
  for cand in "$BUNDLE/go2-bsp" "$BUNDLE" "$BUNDLE/build_pc/go2-bsp-prebuilt"; do
    [ -f "$cand/kernel/prebuilt/Image" ] && { src="$cand"; break; }
  done
  if [ -z "$src" ]; then
    say "  --bundle: no prebuilt blobs under $BUNDLE (looked for kernel/prebuilt/Image)."
    say "    Blobs regenerate from the dump: run 'prepare_assets.sh --with-bsp' (or default) in"
    say "    the analysis repo, then pass --bundle ~/unitree_go2_SOM_analysis"
  else
    say "staging prebuilt blobs from $src ..."
    cp -r "$src/kernel/prebuilt" vendor_bsp/analysis/go2-bsp/kernel/
    cp -r "$src/u-boot/prebuilt" vendor_bsp/analysis/go2-bsp/u-boot/
    say "  prebuilt blobs staged"
  fi
fi

# --- 4. fetch upstreams (optional) -------------------------------------------
[ "$FETCH" = 1 ] && { say "fetching pinned upstreams..."; ./scripts/fetch_sources.sh; }

# --- 5. environment check ----------------------------------------------------
say "checking environment..."
bash scripts/check_env.sh || true

# --- 6. Phase-0 gate ---------------------------------------------------------
if [ "$DO_IMAGES" = 1 ]; then
  if command -v make >/dev/null 2>&1 && [ -f vendor_bsp/analysis/go2-bsp/kernel/prebuilt/Image ]; then
    say "running Phase-0 gate: make images"
    source toolchain/env.sh
    make images && say "DONE — boot.img repacked; toolchain proven."
  else
    say "skipping 'make images' — need 'make' installed AND prebuilt blobs staged."
    say "  install deps:  ./bootstrap.sh --install-deps"
    say "  stage blobs:   ./bootstrap.sh --bundle ~/unitree_go2_SOM_analysis  (after prepare_assets.sh)"
    say "  see docs/WSL-SETUP.md"
  fi
fi
