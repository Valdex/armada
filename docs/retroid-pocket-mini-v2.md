# Retroid Pocket Mini V2 (SM8250) port runbook

This document covers one specific hardware target: an original Retroid Pocket
Mini mainboard fitted with Retroid's replacement "V2" display and running the
Android 13 firmware that reports `Retroid Pocket Mini V2`.

> [!CAUTION]
> This port is experimental and SD-only. Do **not** flash an upstream Armada
> image, do **not** select an SM8650 ABL, and do **not** use Armada's internal
> installer or OTA updater. Those paths are not compatible with the SM8250
> GRUB boot flow yet.

## Exact hardware target

The screen upgrade changes the Linux device target; it does not turn the
Snapdragon 865 mainboard into a newer Qualcomm SoC.

| Property | Required value |
|---|---|
| SoC | Qualcomm SM8250 (Snapdragon 865) |
| Device-tree model | `Retroid Pocket Mini V2` |
| Device-tree compatible | `retroidpocket,rpminiv2`, then `qcom,sm8250` |
| Linux DTB | `sm8250-retroidpocket-rpminiv2.dtb` |
| Panel compatible | `ch13726a,rpminiv2` |
| Native panel mode | 1080 x 1240 at 60 Hz |
| Touch coordinate range | 1080 x 1240 |
| Expected DRM connector | `DSI-1` |
| Test installation target | Removable 256 GB microSD only |

These values are pinned to the successfully booted ROCKNIX 20260701
distribution commit `3e4ee5852e6ca5ea73a38369d2639fad2262648b`:

- [`sm8250-retroidpocket-rpminiv2.dts`](https://github.com/ROCKNIX/distribution/blob/3e4ee5852e6ca5ea73a38369d2639fad2262648b/projects/ROCKNIX/devices/SM8250/linux/dts/qcom/sm8250-retroidpocket-rpminiv2.dts)
- [CH13726A panel modes](https://github.com/ROCKNIX/distribution/blob/3e4ee5852e6ca5ea73a38369d2639fad2262648b/projects/ROCKNIX/devices/SM8250/patches/linux/0058_DDIC-CH13726A-panel.patch)

The Android product name alone is useful evidence but is not the Linux boot
criterion. A successful ROCKNIX baseline must report both the exact DT model
and compatible string above. The original-screen DTB
`sm8250-retroidpocket-rpmini.dtb` selects a 960 x 1280 panel and is not an
acceptable fallback for this unit.

## Non-negotiable safety rules

1. Use only the signed ROCKNIX **SM8250** ABL intended for this SoC. SM8650 is
   a different chip despite the similar number and its ABL must never be
   flashed to this device.
2. Do not flash a stock/upstream Armada disk image. The image must be the
   RP Mini V2 SM8250 build and must retain the ROCKNIX
   `ABL -> EFI/GRUB -> Image + initramfs + separate DTB` path.
3. Keep Android and internal UFS partitions outside the test scope. The first
   port boots and runs entirely from microSD.
4. Keep Armada's internal installer hidden/disabled. It may repartition UFS.
5. Keep Armada OTA disabled. The upstream updater writes an Android-style
   `/KERNEL`, while this port needs an atomic GRUB-aware kernel/DTB update.
6. Do not erase a partition merely because a guide mentions a partition with
   the same name. First capture and verify this device's actual partition map.
7. The SD-only image marks all block devices below the SM8250 internal UFS host
   read-only and sets `UDISKS_IGNORE=1`. Remove that target-specific guard only
   as part of a separately reviewed internal-install design.

## Recovery gate

Do not flash ABL or the test image until every item below is complete.

- [ ] User data that matters is copied off Android.
- [ ] QPST/QFIL sees the device in Qualcomm 9008/EDL mode.
- [ ] The recovery package contains a programmer for **SM8250 UFS**, and QFIL
      accepts the programmer and XML set without performing a write.
- [ ] A complete stock Android 13 recovery package for this exact Mini V2
      configuration is stored off-device with checksums.
- [ ] `abl_a` and `abl_b` have been read from the device, copied off-device,
      checksummed, and verified to be non-empty and the expected size.
- [ ] The GPT/partition layout for every exposed UFS LUN has been captured.
- [ ] QCN/EFS and calibration-related partitions have been backed up where the
      available QPST tooling permits it.
- [ ] Current slot information and the `/dev/block/by-name` mapping have been
      saved with the backup.
- [ ] Android still completes a cold boot before any Linux bootloader change.

If a working ROCKNIX SM8250 ABL is already installed, do not flash it again for
the Armada test. ROCKNIX ABL can force Android by holding **Volume Up** during
boot; verify that escape route before depending on it.

## Capture the ROCKNIX baseline

First boot a current ROCKNIX image that explicitly offers **Retroid Pocket Mini
V2**. Do not begin debugging Armada until this image produces the exact DT
identity and passes the hardware checks below.

The generic SM8250 ROCKNIX image contains several Retroid targets in one GRUB
menu.  On a fresh image the first entry is `Retroid Pocket 5`, not Mini V2, and
the replacement V2 panel may render the firmware/GRUB framebuffer as blue
stripes.  Do not select the unreadable default blindly.  Select
`Retroid Pocket Mini V2`, or preseed the 1024-byte GRUB environment block on
the FAT partition with `saved_entry=rpminiv2`.  A wrong saved entry such as
`rp5` boots the wrong DTB and leaves the panel black even though Linux and the
controller LEDs may otherwise start.

Copy `tools/rpmini-v2-support-bundle.sh` to the device and run it once under
ROCKNIX:

```bash
sudo bash rpmini-v2-support-bundle.sh \
  --output ./rpmini-v2-rocknix-baseline
```

Run it again after Armada reaches a console:

```bash
sudo bash rpmini-v2-support-bundle.sh \
  --output ./rpmini-v2-armada-first-boot
```

The script only reads device/system state and writes its report to the selected
output directory. It deliberately does not collect IP/MAC addresses, SSIDs,
connection profiles, UUIDs, serial numbers, environment variables, user
journals, or application lists. Common identifiers are redacted from the
limited logs it does collect. Automated redaction is not a proof of anonymity;
review every file before sharing the bundle.

Keep the ROCKNIX bundle unchanged. It is the known-good reference for DT, DRM,
input, wireless drivers, audio cards, power supply, fan, thermals and frequency
tables. A recursive diff is a useful first comparison:

```bash
diff -ru rpmini-v2-rocknix-baseline rpmini-v2-armada-first-boot
```

### Observed 20260701 baseline

The physical V2 unit used for this port booted the official ROCKNIX 20260701
image with kernel 7.0.11. The captured baseline verified:

- exact `Retroid Pocket Mini V2` / `retroidpocket,rpminiv2` identity;
- `DSI-1` enabled at 1080 x 1240;
- ROCKNIX root on a loop-backed squashfs, `/flash` on 256 GB microSD
  `mmcblk0p1` read-only, and `/storage` on `mmcblk0p2` read-write;
- the 128 GB internal UFS as separate `sda` through `sdf` LUNs, with no UFS
  filesystem mounted; the 1 TB card was not present or visible;
- QCA6390 Wi-Fi, Retroid gamepad/touch/haptics, the RetroidPocket ALSA card,
  expected CPU frequency limits, and active fan hwmon.

Two ROCKNIX-specific observations must not be mistaken for Armada regressions.
InputPlumber deliberately hides the raw gamepad nodes while it owns them (the
kernel device remains present under `/dev/inputplumber/sources`). Also, ROCKNIX
applies its optional A650 OPP patch and exposes clocks through 800 MHz. The
first Armada build deliberately omits that overclock, so a lower maximum is the
expected safe result.

The first Armada hardware image intentionally does not preseed optional
Flatpaks from live Flathub metadata. This reduces build variability and keeps
the initial test focused on boot, storage, display, input, networking, audio,
power and thermals; optional apps can be installed after those pass.

The baseline charger driver repeatedly logged `Apsd not ready` while attached
through the USB hub. Armada keeps the same detection/retry behavior but demotes
that expected transient to debug level and normalizes the `online` property to
0 or 1. Charging still needs a separate no-hub test before it can pass.

## SD flash and first boot

1. Confirm the artifact name explicitly identifies `rpmini-v2-sm8250` and
   verify its published SHA-256 checksum.
2. Flash that artifact to the expendable 256 GB microSD. Check the selected
   removable drive by capacity and device path before writing. On macOS use
   `tools/flash-rpmini-v2-macos.sh`; it rejects everything except the exact
   256355860480-byte external removable card captured in the baseline and
   performs a full post-write readback hash.
3. Leave internal installation and OTA disabled in the image.
4. This image contains no ABL payload or flashing script. Reuse the already
   working ROCKNIX SM8250 ABL. Preparing a device without that ABL is a separate
   recovery-gated operation and is outside this first-image workflow.
5. Select Linux in ABL. When ABL hands off to GRUB, use the dedicated
   `Retroid Pocket Mini V2` image entries; this build contains no original-panel
   `rpmini` fallback DTB.
6. The first image defaults to the diagnostic/console GRUB entry, not the Steam
   session. That entry also starts SSH for headless recovery; it uses Armada's
   documented initial credentials, so keep it only on a trusted network and
   change the password before enabling SSH in the normal entry.
7. Confirm the root filesystem is on microSD and that no internal Android/UFS
   filesystem has been mounted read-write.
8. Capture the first-boot bundle before changing power, display or input
   settings.

At any unexpected bootloader, partition, or display result: power down, remove
the microSD and force Android with Volume Up. Restore ABL only from the verified
backup and only if Android no longer starts without the card.

## Acceptance matrix

| Area | Minimum pass condition | Stop/rollback condition |
|---|---|---|
| Identity | DT model is `Retroid Pocket Mini V2`; compatible contains `retroidpocket,rpminiv2` and `qcom,sm8250` | Original `rpmini` DTB, unknown model, or any non-SM8250 target |
| Boot isolation | GRUB, kernel, initramfs and root load from microSD; Android boots with the card removed/Volume Up | Unexpected UFS writes, missing Android fallback, or boot loop |
| Display | `DSI-1`, 1080 x 1240 at 60 Hz, correct rotation, stable brightness and no persistent tint/flicker | 960 x 1280 mode, blank panel, corrupted scanout, repeated panel resets |
| Touch | All four corners align with the rotated display and no axis is inverted | Offset, clipped, swapped or inverted coordinates |
| Controls | D-pad, face/shoulder buttons, sticks, analog triggers, Home and volume/power events are distinct and stable | Missing MCU/input node, stuck events, wrong axes or duplicate mappings |
| Rumble/LEDs | Both rumble path and supported LEDs respond without wedging input | MCU reset, stuck vibration, input loss |
| microSD | Root remains mounted, no I/O/timeouts in kernel journal, expansion uses expected card capacity | `mmc` errors, filesystem repair, intermittent disconnect |
| Wi-Fi | QCA6390/ath11k loads firmware and survives reconnect/reboot | Firmware crash, repeated PCIe reset, unavailable radio |
| Bluetooth | Controller/audio discovery and reconnect work after reboot | Missing QCA firmware, transport timeout, radio blocks unexpectedly |
| Audio | Speakers, volume controls and headphone insertion/routing work | Silence, severe distortion, missing card/UCM route |
| Power | Battery capacity/status are plausible; charging/discharging direction is correct | Impossible readings, charging regression, unexpected rapid drain |
| Fan/thermal | Fan control is responsive; temperatures remain bounded under sustained load | Fan absent/stuck, thermal runaway or repeated throttling shutdown |
| CPU/GPU | Valid cpufreq/devfreq tables; A650/Turnip renders without GPU faults | Blind overclock, GPU recovery/hang, missing frequency controls |
| Steam/Gamescope | Gamescope starts at the correct orientation; Steam UI and one ARM64 plus one FEX/Proton workload run | Session loop, wrong resolution/rotation, reproducible GPU fault |
| Lifecycle | Two cold boots, reboot and clean shutdown succeed; fake suspend wakes repeatedly | Failure to wake, data loss, Android fallback regression |

The first SD milestone is complete only after the recovery gate and every
hardware-critical row through fan/thermal passes. Steam performance tuning is a
later stage.

## Features intentionally deferred

OTA may be enabled only after it updates versioned Image/initramfs/DTB files,
switches `grub.cfg` atomically and leaves a known-good rollback entry. Internal
installation requires a separate reviewed design and an explicit decision to
modify UFS. Passing the SD matrix does not authorize either feature.
