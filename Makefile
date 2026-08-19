# rk3588S2_uni — umbrella build.
# Each layer has its own directory; these targets dispatch into them.
# Run inside WSL2 Ubuntu 22.04 after: source toolchain/env.sh

# Reconstructed BSP: go2-bsp inside the analysis-repo submodule.
GO2_BSP ?= vendor_bsp/analysis/go2-bsp

.PHONY: help env fetch check bsp kernel rootfs images apps ai image flash verify submodules clean

help:
	@echo "Targets:"
	@echo "  check     verify host toolchain + deps (scripts/check_env.sh)"
	@echo "  fetch     pull pinned upstreams into third_party/ (scripts/fetch_sources.sh)"
	@echo "  submodules  init/update the go2-bsp submodule (vendor_bsp/analysis)"
	@echo "  images    Phase-0 gate: repack boot.img from prebuilt Image (go2-bsp)"
	@echo "  kernel    Layer 1: build custom kernel Image + DTBs"
	@echo "  rootfs    Layer 1: build rootfs.img (debootstrap; needs root/fakeroot)"
	@echo "  apps      Layer 2: cross-compile unitree_sdk2 apps (apps/)"
	@echo "  ai        Layer 3: build NPU runtime + demos (ai/)"
	@echo "  image     assemble a flashable image set into bsp/out/"
	@echo "  verify    pre-flash size/partition/SHA gate (flash/verify.sh)"
	@echo "  flash     GUARDED flash (refuses unless RK_ALLOW_FLASH=1; separate host)"

check:
	@bash scripts/check_env.sh

fetch:
	@bash scripts/fetch_sources.sh

submodules:
	@git submodule update --init --depth 1 vendor_bsp/analysis
	@# submodule scripts may be stored non-executable (Windows git); make them runnable
	@find vendor_bsp/analysis -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

# Phase-0 gate: proves the toolchain reproduces a valid boot.img with no source build.
images:
	@test -f $(GO2_BSP)/Makefile || { echo "go2-bsp missing — run 'make submodules' (and transfer prebuilt blobs; see docs/MIGRATION.md)"; exit 2; }
	@chmod +x $(GO2_BSP)/scripts/*.sh 2>/dev/null || true
	@$(MAKE) -C $(GO2_BSP) images

kernel:
	@$(MAKE) -C bsp/kernel

rootfs:
	@$(MAKE) -C bsp/rootfs

apps:
	@cmake -S apps -B apps/build -DCMAKE_TOOLCHAIN_FILE=apps/cmake/aarch64-toolchain.cmake && cmake --build apps/build

ai:
	@$(MAKE) -C ai

image: kernel
	@$(MAKE) -C bsp/pack

verify:
	@bash flash/verify.sh

flash:
	@bash flash/flash.sh
