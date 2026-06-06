#!/bin/bash
set -euxo pipefail

KVER="7.0.11"
TARBALL="/ctx/vendor/kernel/armada-kernel-${KVER}.tar.zst"
EXPECTED_SHA256="47d4fae05ee9ba07c462e35539fe7f0df75946d53d760780eb80594fb40318a8"

# bootc expects exactly one kernel under /usr/lib/modules.
dnf5 -y remove kernel kernel-core kernel-modules kernel-modules-core 2>/dev/null || true
rm -rf /usr/lib/modules/*

[ -f "${TARBALL}" ] || { echo "ERROR: kernel tarball missing at ${TARBALL}"; exit 1; }
echo "${EXPECTED_SHA256}  ${TARBALL}" | sha256sum -c -

tar --extract --zstd -f "${TARBALL}" -C /usr/
depmod -a "${KVER}" -b /

# Dracut config must exist before initramfs generation.
install -Dpm 0644 \
    /ctx/system_files/usr/lib/dracut/dracut.conf.d/10-armada.conf \
    /usr/lib/dracut/dracut.conf.d/10-armada.conf

# dracut MODULE_FIRMWARE introspection needs firmware at the build-time path.
mkdir -p /usr/lib/firmware
cp -a /ctx/system_files/usr/lib/firmware/. /usr/lib/firmware/

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

echo "armada kernel ${KVER} installed at /usr/lib/modules/${KVER}/"
ls -la "/usr/lib/modules/${KVER}/" | head -10
