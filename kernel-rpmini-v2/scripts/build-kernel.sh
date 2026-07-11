#!/usr/bin/env bash
# Build the exact ROCKNIX SM8250 hardware kernel as an Armada kernel carrier.
# Runs natively on aarch64; the outer build.sh supplies the Fedora toolchain.

set -euo pipefail

PACKAGE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${PACKAGE_ROOT}/BASE.env"

WORK_DIR=${WORK_DIR:-/var/tmp/armada-rpmini-v2-kernel}
OUT_DIR=${OUT_DIR:-${PACKAGE_ROOT}/out}
ROCKNIX_SOURCE=${ROCKNIX_SOURCE:-}
JOBS=${JOBS:-$(nproc)}

if [[ $(uname -m) != aarch64 ]]; then
    echo "ERROR: the RP Mini V2 kernel build must run natively on aarch64" >&2
    exit 1
fi

mkdir -p "${WORK_DIR}" "${OUT_DIR}"
rm -f "${OUT_DIR}"/armada-kernel-*.tar.zst "${OUT_DIR}"/armada-kernel-*.tar.zst.sha256

if [[ -n ${ROCKNIX_SOURCE} ]]; then
    ROCKNIX_SOURCE=$(realpath "${ROCKNIX_SOURCE}")
    [[ -d ${ROCKNIX_SOURCE}/.git ]] || {
        echo "ERROR: ROCKNIX_SOURCE is not a git checkout: ${ROCKNIX_SOURCE}" >&2
        exit 1
    }
    actual_commit=$(git -C "${ROCKNIX_SOURCE}" rev-parse HEAD)
    [[ ${actual_commit} == "${ROCKNIX_COMMIT}" ]] || {
        echo "ERROR: ROCKNIX_SOURCE is ${actual_commit}, expected ${ROCKNIX_COMMIT}" >&2
        exit 1
    }
else
    ROCKNIX_SOURCE=${WORK_DIR}/rocknix
    if [[ ! -d ${ROCKNIX_SOURCE}/.git ]] || \
       [[ $(git -C "${ROCKNIX_SOURCE}" rev-parse HEAD 2>/dev/null || true) != "${ROCKNIX_COMMIT}" ]]; then
        rm -rf "${ROCKNIX_SOURCE}"
        git init -q "${ROCKNIX_SOURCE}"
        git -C "${ROCKNIX_SOURCE}" remote add origin https://github.com/ROCKNIX/distribution.git
        git -C "${ROCKNIX_SOURCE}" fetch --depth=1 origin "${ROCKNIX_COMMIT}"
        git -C "${ROCKNIX_SOURCE}" checkout -q --detach FETCH_HEAD
    fi
fi

TARBALL=${WORK_DIR}/linux-${KERNEL_VERSION}.tar.xz
if [[ ! -f ${TARBALL} ]] || ! printf '%s  %s\n' "${KERNEL_SHA256}" "${TARBALL}" | sha256sum -c -; then
    rm -f "${TARBALL}"
    curl --fail --location --retry 3 \
        --output "${TARBALL}" \
        "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${KERNEL_VERSION}.tar.xz"
fi
printf '%s  %s\n' "${KERNEL_SHA256}" "${TARBALL}" | sha256sum -c -

SOURCE_DIR=${WORK_DIR}/linux-${KERNEL_VERSION}
rm -rf "${SOURCE_DIR}"
tar -C "${WORK_DIR}" -xf "${TARBALL}"
cd "${SOURCE_DIR}"

applied=0
while IFS= read -r relative; do
    relative=${relative%%#*}
    relative=${relative%$'\r'}
    [[ -n ${relative//[[:space:]]/} ]] || continue
    patch_file=${ROCKNIX_SOURCE}/${relative}
    [[ -f ${patch_file} ]] || {
        echo "ERROR: pinned ROCKNIX patch is missing: ${relative}" >&2
        exit 1
    }
    echo "==> applying ${relative}"
    patch -Np1 --batch --forward < "${patch_file}"
    applied=$((applied + 1))
done < "${PACKAGE_ROOT}/patches.list"

# Small Armada follow-ups to the pinned ROCKNIX hardware patches. Keep these
# separate so the downstream delta is explicit and independently reviewable.
local_applied=0
for patch_file in "${PACKAGE_ROOT}"/patches/*.patch; do
    [[ -f ${patch_file} ]] || continue
    echo "==> applying Armada follow-up ${patch_file#"${PACKAGE_ROOT}/"}"
    patch -Np1 --batch --forward < "${patch_file}"
    local_applied=$((local_applied + 1))
done

CHARGER_SOURCE=drivers/power/supply/qcom_pm8150b_charger.c
grep -Fq '*val = !!(stat & USBIN_PLUGIN_RT_STS_BIT);' "${CHARGER_SOURCE}" || {
    echo "ERROR: PM8150B online state was not normalized to a boolean" >&2
    exit 1
}
grep -Fq 'dev_dbg(chip->dev, "APSD not ready\n");' "${CHARGER_SOURCE}" || {
    echo "ERROR: expected-while-probing APSD state still logs as an error" >&2
    exit 1
}

DTS_SOURCE=${ROCKNIX_SOURCE}/projects/ROCKNIX/devices/SM8250/linux/dts/qcom
DTS_TARGET=${SOURCE_DIR}/arch/arm64/boot/dts/qcom
for name in \
    sm8250-retroidpocket-common.dtsi \
    sm8250-retroidpocket-rpmini.dts \
    sm8250-retroidpocket-rpminiv2.dts; do
    install -m 0644 "${DTS_SOURCE}/${name}" "${DTS_TARGET}/${name}"
done

if ! grep -q '# Armada RP Mini V2 DTBs' "${DTS_TARGET}/Makefile"; then
    cat >> "${DTS_TARGET}/Makefile" <<'EOF'

# Armada RP Mini V2 DTBs
dtb-$(CONFIG_ARCH_QCOM) += sm8250-retroidpocket-rpmini.dtb
dtb-$(CONFIG_ARCH_QCOM) += sm8250-retroidpocket-rpminiv2.dtb
EOF
fi

CONFIG_SOURCE=${ROCKNIX_SOURCE}/projects/ROCKNIX/devices/SM8250/linux/linux.aarch64.conf
install -m 0644 "${CONFIG_SOURCE}" .config
scripts/config --set-str CONFIG_DEFAULT_HOSTNAME armada
scripts/config --set-str CONFIG_INITRAMFS_SOURCE ''
scripts/config --set-str CONFIG_LOCALVERSION -armada-rpmini-v2
scripts/config --disable CONFIG_LOCALVERSION_AUTO
scripts/config --enable CONFIG_OVERLAY_FS
# bootc/OSTree mounts a file-backed EROFS metadata image and layers it with
# overlayfs during ostree-prepare-root.  These must be built in because that
# happens before switch_root; relying on a module in the real root is too late.
scripts/config --enable CONFIG_BLK_DEV_LOOP
scripts/config --enable CONFIG_EROFS_FS
scripts/config --enable CONFIG_EROFS_FS_XATTR
scripts/config --enable CONFIG_EROFS_FS_POSIX_ACL
scripts/config --enable CONFIG_EROFS_FS_SECURITY
scripts/config --enable CONFIG_EROFS_FS_BACKED_BY_FILE
scripts/config --enable CONFIG_FS_VERITY
scripts/config --enable CONFIG_FW_LOADER_COMPRESS
scripts/config --enable CONFIG_FW_LOADER_COMPRESS_XZ
scripts/config --enable CONFIG_FW_LOADER_COMPRESS_ZSTD
scripts/config --enable CONFIG_RD_ZSTD
scripts/config --enable CONFIG_SYSFB_SIMPLEFB
scripts/config --enable CONFIG_UCLAMP_TASK
scripts/config --enable CONFIG_UCLAMP_TASK_GROUP
scripts/config --module CONFIG_SND_SEQUENCER
scripts/config --disable CONFIG_WERROR
make -j"${JOBS}" ARCH=arm64 olddefconfig

for required in \
    CONFIG_EFI_STUB \
    CONFIG_BTRFS_FS \
    CONFIG_OVERLAY_FS \
    CONFIG_BLK_DEV_LOOP \
    CONFIG_EROFS_FS \
    CONFIG_EROFS_FS_XATTR \
    CONFIG_EROFS_FS_POSIX_ACL \
    CONFIG_EROFS_FS_SECURITY \
    CONFIG_EROFS_FS_BACKED_BY_FILE \
    CONFIG_FS_VERITY \
    CONFIG_FW_LOADER_COMPRESS \
    CONFIG_FW_LOADER_COMPRESS_XZ \
    CONFIG_FW_LOADER_COMPRESS_ZSTD \
    CONFIG_RD_ZSTD \
    CONFIG_SYSFB_SIMPLEFB \
    CONFIG_UCLAMP_TASK \
    CONFIG_UCLAMP_TASK_GROUP \
    CONFIG_DRM_MSM \
    CONFIG_DRM_PANEL_DDIC_CH13726A \
    CONFIG_TOUCHSCREEN_EDT_FT5X06 \
    CONFIG_PINCTRL_SM8250 \
    CONFIG_INTERCONNECT_QCOM_SM8250 \
    CONFIG_MMC_SDHCI_MSM \
    CONFIG_SCSI_UFS_QCOM; do
    grep -q "^${required}=y$" .config || {
        echo "ERROR: required built-in kernel option did not survive: ${required}" >&2
        exit 1
    }
done
grep -Eq '^CONFIG_JOYSTICK_RETROID=(y|m)$' .config
grep -Eq '^CONFIG_ATH11K=(y|m)$' .config
for required in \
    CONFIG_BT_HCIUART_QCA \
    CONFIG_INPUT_QCOM_SPMI_HAPTICS \
    CONFIG_CHARGER_QCOM_SMB5 \
    CONFIG_BATTERY_QCOM_FG \
    CONFIG_SENSORS_PWM_FAN \
    CONFIG_SND_SOC_SM8250 \
    CONFIG_SND_SEQUENCER \
    CONFIG_USB_RTL8152 \
    CONFIG_LEDS_HTR3212; do
    grep -Eq "^${required}=(y|m)$" .config || {
        echo "ERROR: required RP Mini V2 kernel option did not survive: ${required}" >&2
        exit 1
    }
done

export KBUILD_BUILD_USER=armada
export KBUILD_BUILD_HOST=rpmini-v2-builder
make -j"${JOBS}" ARCH=arm64 Image dtbs modules

KVER=$(make -s ARCH=arm64 kernelrelease)
STAGE=${WORK_DIR}/stage-${KVER}
rm -rf "${STAGE}"
mkdir -p "${STAGE}/lib/modules/${KVER}/dtb/qcom"
install -m 0644 arch/arm64/boot/Image "${STAGE}/lib/modules/${KVER}/vmlinuz"
install -m 0644 .config "${STAGE}/lib/modules/${KVER}/config"
make -j"${JOBS}" ARCH=arm64 INSTALL_MOD_PATH="${STAGE}" INSTALL_MOD_STRIP=1 modules_install
rm -f "${STAGE}/lib/modules/${KVER}/build" "${STAGE}/lib/modules/${KVER}/source"

for name in sm8250-retroidpocket-rpmini sm8250-retroidpocket-rpminiv2; do
    install -m 0644 \
        "arch/arm64/boot/dts/qcom/${name}.dtb" \
        "${STAGE}/lib/modules/${KVER}/dtb/qcom/${name}.dtb"
done

cat > "${STAGE}/lib/modules/${KVER}/.armada-source" <<EOF
Source: linux-${KERNEL_VERSION} (kernel.org, sha256 ${KERNEL_SHA256})
ROCKNIX: ${ROCKNIX_COMMIT}
ROCKNIX patches: ${applied} entries from kernel-rpmini-v2/patches.list
Armada follow-up patches: ${local_applied} entries from kernel-rpmini-v2/patches/
Target: Retroid Pocket Mini V2 (retroidpocket,rpminiv2)
GPU overclock patch: excluded
EOF

OUT_NAME=armada-kernel-${KVER}.tar.zst
tar -C "${STAGE}" --owner=0 --group=0 -cf - lib \
    | zstd -f -10 -T0 -o "${OUT_DIR}/${OUT_NAME}"
(cd "${OUT_DIR}" && sha256sum "${OUT_NAME}" > "${OUT_NAME}.sha256")

echo "Built RP Mini V2 kernel carrier payload:"
ls -lh "${OUT_DIR}/${OUT_NAME}" "${OUT_DIR}/${OUT_NAME}.sha256"
