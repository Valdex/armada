#!/bin/bash
set -euxo pipefail

# Firmware for unrelated hardware. The RP Mini V2 baseline uses the user's
# RTL8153 USB Ethernet adapter as its wired rescue path, so keep that target's
# Realtek NIC firmware.
firmware_packages=(
    amd-gpu-firmware \
    amd-ucode-firmware \
    brcmfmac-firmware \
    cirrus-audio-firmware \
    intel-audio-firmware \
    intel-gpu-firmware \
    mt7xxx-firmware \
    nvidia-gpu-firmware \
    nxpwireless-firmware \
    qcom-wwan-firmware \
    tiwilink-firmware
)
if [[ "$(</usr/lib/armada/build-target)" != retroid-pocket-mini-v2 ]]; then
    firmware_packages+=(realtek-firmware)
fi
dnf5 -y remove --no-autoremove "${firmware_packages[@]}"

rm -f /usr/lib/binfmt.d/qemu-*.conf

# AWS SDK chain from the bootc base.
dnf5 -y remove --no-autoremove \
    python3-boto3 \
    python3-botocore \
    python3-s3transfer

dnf5 -y remove --no-autoremove binutils

for required in qcom-firmware atheros-firmware bootc podman skopeo gamescope gamescope-session fex-emu-utils mangohud; do
    rpm -q "$required" >/dev/null || { echo "ERROR: $required got removed"; exit 1; }
done

# The patched Turnip (Mesa #14656 fix) must be the installed one, not stock Fedora.
case "$(rpm -q --qf '%{release}' mesa-vulkan-drivers)" in
    *armada*) ;;
    *) echo "ERROR: stock mesa-vulkan-drivers installed; patched .armada Turnip lost"; exit 1 ;;
esac

# The patched mangohud (Adreno SM8550 sysfs repoints) must be the installed one.
case "$(rpm -q --qf '%{release}' mangohud)" in
    *armada*) ;;
    *) echo "ERROR: stock mangohud installed; patched .armada mangohud lost"; exit 1 ;;
esac

firmware_paths=(
    /usr/lib/firmware/amdgpu \
    /usr/lib/firmware/amd-ucode \
    /usr/lib/firmware/brcm \
    /usr/lib/firmware/cirrus \
    /usr/lib/firmware/cypress \
    /usr/lib/firmware/intel \
    /usr/lib/firmware/i915 \
    /usr/lib/firmware/iwlwifi-* \
    /usr/lib/firmware/mediatek \
    /usr/lib/firmware/mrvl \
    /usr/lib/firmware/nvidia \
    /usr/lib/firmware/nxp \
    /usr/lib/firmware/rtw89 \
    /usr/lib/firmware/ti-connectivity \
    /usr/lib/firmware/xe
)
if [[ "$(</usr/lib/armada/build-target)" != retroid-pocket-mini-v2 ]]; then
    firmware_paths+=(/usr/lib/firmware/rtl_nic)
fi
rm -rf "${firmware_paths[@]}"

if [[ "$(</usr/lib/armada/build-target)" == retroid-pocket-mini-v2 ]]; then
    rpm -q realtek-firmware >/dev/null || {
        echo "ERROR: RP Mini V2 wired-rescue firmware package is missing" >&2
        exit 1
    }
    [[ -e /usr/lib/firmware/rtl_nic/rtl8153a-4.fw \
        || -e /usr/lib/firmware/rtl_nic/rtl8153a-4.fw.xz \
        || -e /usr/lib/firmware/rtl_nic/rtl8153a-4.fw.zst ]] || {
        echo "ERROR: RP Mini V2 wired-rescue firmware rtl8153a-4 is missing" >&2
        exit 1
    }
fi
