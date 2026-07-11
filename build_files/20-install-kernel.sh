#!/bin/bash
set -euxo pipefail

KERNEL_DIR=/packages/kernel
mapfile -t TARBALLS < <(find "${KERNEL_DIR}" -maxdepth 1 -type f -name 'armada-kernel-*.tar.zst' -print | sort)
[ "${#TARBALLS[@]}" -eq 1 ] || {
    echo "ERROR: expected exactly one armada kernel tarball in ${KERNEL_DIR}, found ${#TARBALLS[@]}" >&2
    printf '  %s\n' "${TARBALLS[@]:-<none>}" >&2
    exit 1
}
TARBALL="${TARBALLS[0]}"
CHECKSUM="${TARBALL}.sha256"

# bootc expects exactly one kernel under /usr/lib/modules.
dnf5 -y remove kernel kernel-core kernel-modules kernel-modules-core 2>/dev/null || true
rm -rf /usr/lib/modules/*

# Verify the shipped checksum before extracting it.
[ -f "${CHECKSUM}" ] || { echo "ERROR: kernel checksum missing at ${CHECKSUM}"; exit 1; }
( cd "${KERNEL_DIR}" && sha256sum -c "$(basename "${CHECKSUM}")" )

tar --extract --zstd -f "${TARBALL}" -C /usr/
mapfile -t KERNEL_MODULE_DIRS < <(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -print | sort)
[ "${#KERNEL_MODULE_DIRS[@]}" -eq 1 ] || {
    echo "ERROR: kernel package must install exactly one modules tree, found ${#KERNEL_MODULE_DIRS[@]}" >&2
    printf '  %s\n' "${KERNEL_MODULE_DIRS[@]:-<none>}" >&2
    exit 1
}
KVER=$(basename "${KERNEL_MODULE_DIRS[0]}")
depmod -a "${KVER}" -b /

# Dracut config must exist before initramfs generation.
install -Dpm 0644 \
    /ctx/system_files/usr/lib/dracut/dracut.conf.d/10-armada.conf \
    /usr/lib/dracut/dracut.conf.d/10-armada.conf

# dracut MODULE_FIRMWARE introspection needs firmware at the build-time path.
mkdir -p /usr/lib/firmware
cp -a /ctx/system_files/usr/lib/firmware/. /usr/lib/firmware/

if [[ "$(</usr/lib/armada/build-target)" == retroid-pocket-mini-v2 ]]; then
    install -Dpm 0644 \
        /ctx/system_files/usr/lib/dracut/dracut.conf.d/11-armada-rpmini-v2.conf \
        /usr/lib/dracut/dracut.conf.d/11-armada-rpmini-v2.conf
    install -Dpm 0644 \
        /ctx/system_files/usr/lib/udev/rules.d/99-armada-rpmini-v2-ufs-readonly.rules \
        /usr/lib/udev/rules.d/99-armada-rpmini-v2-ufs-readonly.rules
    install -Dpm 0755 \
        /ctx/system_files/usr/libexec/armada/rpmini-v2-ufs-readonly \
        /usr/libexec/armada/rpmini-v2-ufs-readonly
    install -Dpm 0644 \
        /ctx/system_files/usr/lib/systemd/system/armada-rpmini-v2-ufs-guard.service \
        /usr/lib/systemd/system/armada-rpmini-v2-ufs-guard.service
    mkdir -p /usr/lib/systemd/system/initrd-root-fs.target.requires
    ln -sfn ../armada-rpmini-v2-ufs-guard.service \
        /usr/lib/systemd/system/initrd-root-fs.target.requires/armada-rpmini-v2-ufs-guard.service
    command -v blockdev >/dev/null || {
        echo "ERROR: blockdev is required for the RP Mini V2 UFS read-only guard" >&2
        exit 1
    }

    # linux-firmware stores the RB5 SLPI payload under its board directory,
    # while the Retroid DTS requests the generic sm8250 path. Match ROCKNIX's
    # packaging without copying or vendoring the Qualcomm blob.
    for suffix in '' .xz .zst; do
        slpi_source="/usr/lib/firmware/qcom/sm8250/Thundercomm/RB5/slpi.mbn${suffix}"
        slpi_target="/usr/lib/firmware/qcom/sm8250/slpi.mbn${suffix}"
        if [[ -e "${slpi_source}" && ! -e "${slpi_target}" ]]; then
            ln -s "Thundercomm/RB5/slpi.mbn${suffix}" "${slpi_target}"
        fi
    done

    require_firmware() {
        local relative=$1
        [[ -e "/usr/lib/firmware/${relative}" \
            || -e "/usr/lib/firmware/${relative}.xz" \
            || -e "/usr/lib/firmware/${relative}.zst" ]] || {
            echo "ERROR: RP Mini V2 firmware is missing: ${relative}[.xz|.zst]" >&2
            exit 1
        }
    }

    require_firmware qcom/a650_gmu.bin
    require_firmware qcom/a650_sqe.fw
    require_firmware qcom/sm8250/a650_zap.mbn
    require_firmware qcom/sm8250/adsp.mbn
    require_firmware qcom/sm8250/cdsp.mbn
    require_firmware qcom/sm8250/slpi.mbn
    require_firmware qcom/vpu-1.0/venus.mbn
    require_firmware qca/htbtfw20.tlv
    require_firmware qca/htnv20.bin
    require_firmware rtl_nic/rtl8153a-4.fw

    require_firmware ath11k/QCA6390/hw2.0/amss.bin
    require_firmware ath11k/QCA6390/hw2.0/board-2.bin
    require_firmware ath11k/QCA6390/hw2.0/m3.bin
fi

# Plymouth theme must exist before dracut bakes the splash into initramfs.
mkdir -p /usr/share/plymouth/themes
cp -a /ctx/system_files/usr/share/plymouth/themes/armada /usr/share/plymouth/themes/

plymouth-set-default-theme armada

dracut \
    --force \
    --no-hostonly \
    --reproducible \
    --kver "${KVER}" \
    --add ostree \
    --add plymouth \
    "/usr/lib/modules/${KVER}/initramfs.img" "${KVER}"

if [[ "$(</usr/lib/armada/build-target)" == retroid-pocket-mini-v2 ]]; then
    command -v lsinitrd >/dev/null || {
        echo "ERROR: lsinitrd is required to verify the RP Mini V2 safety guard" >&2
        exit 1
    }
    INITRAMFS_LIST=$(mktemp)
    lsinitrd "/usr/lib/modules/${KVER}/initramfs.img" > "${INITRAMFS_LIST}"
    for required in \
        usr/bin/bash \
        usr/lib/udev/rules.d/99-armada-rpmini-v2-ufs-readonly.rules \
        usr/libexec/armada/rpmini-v2-ufs-readonly \
        usr/lib/systemd/system/armada-rpmini-v2-ufs-guard.service \
        usr/lib/systemd/system/initrd-root-fs.target.requires/armada-rpmini-v2-ufs-guard.service; do
        grep -Fq "${required}" "${INITRAMFS_LIST}" || {
            echo "ERROR: RP Mini V2 initramfs is missing ${required}" >&2
            exit 1
        }
    done
    grep -Eq 'usr/(sbin|bin)/blockdev([[:space:]]|$)' "${INITRAMFS_LIST}" || {
        echo "ERROR: RP Mini V2 initramfs is missing blockdev" >&2
        exit 1
    }
    rm -f "${INITRAMFS_LIST}"
fi

echo "armada kernel ${KVER} installed from $(basename "${TARBALL}") at /usr/lib/modules/${KVER}/"
ls -la "/usr/lib/modules/${KVER}/" | head -10
