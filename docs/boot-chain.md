# Boot chain & constraints (RK3588S2 Go2 SOM)

Recovered from the eMMC dump (see the analysis repo). This is the ground truth a
custom BSP must respect.

## Chain

```
BootROM (maskrom)
  -> idbloader.img  (DDR init + SPL / MiniLoader)
    -> ATF BL31     (3 load regions; load 0x40000)
      -> OP-TEE     (secure world; load 0x8400000)
        -> U-Boot   (FIT v17; load 0x200000)
          -> FIT "go2"  ->  Linux 5.10.176-rt86+  (Image load 0x400000)
```

- **Signed FIT, RSA-2048/PSS**, with **rollback protection**. The `uboot`/`boot`
  partitions are signed; substituting unsigned images breaks the chain unless you
  provision your own keys and manage the rollback fuses.
- **Default safe posture:** keep `idbloader.img` + `uboot.img` **byte-exact** from
  the stock set; replace only `boot` (kernel FIT) and `rootfs`.

## Kernel

- `5.10.176-rt86+`, `CONFIG_PREEMPT_RT=y`, arm64, boots **without initramfs**.
- Cmdline: `earlycon=uart8250,mmio32,0xfeb50000 console=ttyFIQ0 root=PARTUUID=614e0000-0000 rw rootwait isolcpus=3`
- **`isolcpus=3`** — CPU3 isolated for real-time locomotion. Keep it.
- Toolchain: `aarch64-none-linux-gnu-gcc 10.3.1` (ARM GNU 10.3-2021.07). Match it.

## Device trees

- `rk3588s-go2.dts` and `rk3588s-go2-cy.dts` (the "chuany" HW revision).
- `compatible = "unitree,rk3588s-go2", "iflytek,rk3588s-hh-navbox", "rockchip,rk3588"`.
- NPU (`rockchip,rk3588-rknpu`, 3 cores) and Mali-Valhall GPU are enabled here.

## Partitions (GPT)

Two baselines exist and must be reconciled before repartitioning:
- `go2-bsp/config/parameter.txt` — `FIRMWARE_VER 1.0`, `MACHINE_MODEL RK3588`.
- `rkdevtool_image/parameter.txt` — `FIRMWARE_VER 1.1.15`, `MACHINE_MODEL RK3588S`, `userdata:grow`.

`rootfs` mounts **rw** and is **not** dm-verity protected → editable. `uni` (identity)
and `userdata` (calibration/state) are off-limits.

## What QEMU can and cannot prove

- **Can:** rootfs userland (Tier-2 chroot), full arm64 boot on a generic kernel
  (Tier-3) — catches init/userspace regressions.
- **Cannot:** the signed RK boot chain, OP-TEE, rollback fuses. Hardware is the final
  word on anything below U-Boot.
