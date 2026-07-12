# SSC (Snapdragon Sensor Core) accel+gyro bring-up — RP Mini V2

The IMU sits on the SLPI's private bus and is unreachable from the AP; the
only path is through the sensor DSP. On this unit (original RP Mini board,
Android 10 "kona-iot") the chip is an ST LSM6DST on SSC I3C bus 1 (0x6A
rigid_body=display / 0x6B, orient -x,+y,-z per `kona_lsm6dst_*.json`); newer
Retroid boards (RP5/RP6/Flip 2) use a QST QMI8658 instead. Vendored from
ROCKNIX PR #3005
(AYN Odin 3 / SM8750, head `1a6032db33a056065a373c36745872ca41e1387c`), adapted
for SM8250: the sensor DSP is the dedicated SLPI (fastrpc domain `sdsp`,
`/dev/fastrpc-sdsp`), not the ADSP.

- `snsfeed.c` — QMI-over-QRTR client for SSC service 400 (`sns_client`);
  resolves accel/gyro SUIDs, streams at N Hz, feeds `/dev/sns_iio_feed`.
- `daemon_main.c`, `bsd_shim.c` — tiny main + strlcpy shim for building
  `adsprpcd` from qualcomm/fastrpc `706071caca54b9a56d78793c30d04351de5fbd96`
  (see the sensors-build stage in the Containerfile).
- Kernel side: `kernel-rpmini-v2/patches/0003-iio-sns-iio-ssc-imu-bridge.patch`
  (`CONFIG_SNS_IIO=m`) exposes the fed samples as IIO device `bmi323-imu`,
  which stock InputPlumber's iio_imu driver picks up.

Runtime pieces live in `system_files`: `rpmini-sensors.service` +
`/usr/libexec/armada/rpmini-sensors-start`. The Hexagon sensor registry
(`/usr/share/qcom-hexagon-fs`) and `qcom/sm8250/slpi.mbn` firmware must be
dumped from the device's own Android partitions (kona `*.json` registry from
`/vendor/etc/sensors/`, per-unit calibration from `/mnt/vendor/persist/sensors/`);
the service stays inert (ConditionPathExists) until they are committed.
