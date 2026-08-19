# rk3588S2_uni — umbrella build.
# Each layer has its own directory; these targets dispatch into them.
# Run inside WSL2 Ubuntu 22.04 after: source toolchain/env.sh

.PHONY: help env fetch check bsp kernel rootfs images apps ai image flash verify clean

help:
	@echo "Targets:"
	@echo "  check     verify host toolchain + deps (scripts/check_env.sh)"
	@echo "  fetch     pull pinned upstreams into third_party/ (scripts/fetch_sources.sh)"
	@echo "  images    Phase-0 gate: repack boot.img from prebuilt Image (vendor_bsp)"
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

# Phase-0 gate: proves the toolchain reproduces a valid boot.img with no source build.
images:
	@$(MAKE) -C vendor_bsp images

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
