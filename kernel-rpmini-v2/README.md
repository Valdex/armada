# RP Mini V2 kernel carrier

This package builds the SM8250 kernel used by the dedicated Armada image. It
pins Linux 7.0.11, the exact ROCKNIX 20260701 source commit, the kernel.org tarball checksum,
the exact Retroid Pocket Mini/V2 DTS files, and a curated ROCKNIX patch list.

The first bring-up intentionally reproduces the kernel and device tree from
the image already booted on the physical unit. It excludes ROCKNIX's
`9998-gpu-opp-table.patch` so the Adreno A650 stays at normal operating points,
and excludes `9999-remove-log-spam.patch` so real hardware faults remain visible.

The small patches under `patches/` are Armada-owned follow-ups applied after
the pinned ROCKNIX list. The initial follow-up normalizes the charger's
`online` property to `0`/`1` and stops the expected APSD-retry state from
flooding the kernel error log; it does not alter charger detection or limits.

The carrier also enables EROFS (including file-backed images and extended
attributes), OverlayFS and fs-verity as built-ins. Fedora bootc's
`ostree-prepare-root` needs those before `switch_root` to mount ComposeFS. The
generated diagnostic GRUB entry disables ComposeFS explicitly so it remains a
usable recovery path if that early mount ever regresses.

On a native ARM64 Linux host:

```sh
./kernel-rpmini-v2/build.sh
podman build -f kernel-rpmini-v2/Carrierfile \
  -t localhost/armada-packages/kernel:latest kernel-rpmini-v2
```

For an offline/review build, set `ROCKNIX_SOURCE` to a checkout whose HEAD is
the commit in `BASE.env`. CI normally fetches that pinned commit itself.
