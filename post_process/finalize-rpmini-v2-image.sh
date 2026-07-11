#!/usr/bin/env bash
# Finalize the dedicated Retroid Pocket Mini V2 (SM8250) SD image.
#
# Unlike the universal Armada path, this keeps EFI enabled and stages a
# ROCKNIX-style ABL -> EFI/GRUB -> raw Image + initramfs + DTB chain.  Every
# hardware-specific artifact must come from the exact deployment selected by
# BLS; ambiguity is an error, not a reason to guess.
set -euo pipefail

readonly DEVICE_TARGET="retroid-pocket-mini-v2"
readonly EXPECTED_DTB="sm8250-retroidpocket-rpminiv2.dtb"
readonly EXPECTED_DTB_REL="qcom/${EXPECTED_DTB}"

RAW_IMAGE="${1:-output/image/disk.raw}"
OUT="${OUT:-output/armada-rpmini-v2-sm8250-$(TZ='America/New_York' date +%Y%m%d).img.gz}"
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY_ARTIFACTS="${REPO_ROOT}/post_process/verify-rpmini-v2-boot-artifacts.py"
GRUB_MKIMAGE="${GRUB_MKIMAGE:-}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

for command in awk blkid blockdev cmp cp dd df du fatlabel find getconf \
    grep install jq losetup lsinitrd mount pigz python3 realpath sed sfdisk \
    sha256sum sort sudo umount; do
    command -v "${command}" >/dev/null 2>&1 || die "missing required command: ${command}"
done

if [[ -z "${GRUB_MKIMAGE}" ]]; then
    GRUB_MKIMAGE=$(command -v grub-mkimage || command -v grub2-mkimage || true)
fi
[[ -n "${GRUB_MKIMAGE}" ]] \
    || die "missing grub-mkimage/grub2-mkimage (install grub-efi-arm64-bin or grub2-efi-aa64-modules)"

[[ -f "${RAW_IMAGE}" ]] || die "raw image not found: ${RAW_IMAGE}"
[[ -x "${VERIFY_ARTIFACTS}" ]] || die "artifact verifier is missing or not executable: ${VERIFY_ARTIFACTS}"
[[ "$(realpath -m -- "${RAW_IMAGE}")" != "$(realpath -m -- "${OUT}")" ]] \
    || die "output path must not overwrite the raw image"

WORK=$(mktemp -d)
LOOP=""
P1_MOUNTED=0
P2_MOUNTED=0

cleanup() {
    local rc=$?
    set +e
    if (( P1_MOUNTED )); then sudo umount "${WORK}/p1"; fi
    if (( P2_MOUNTED )); then sudo umount "${WORK}/p2"; fi
    if [[ -n "${LOOP}" ]]; then sudo losetup -d "${LOOP}"; fi
    rm -rf "${WORK}"
    exit "${rc}"
}
trap cleanup EXIT INT TERM

mkdir -p "${WORK}/p1" "${WORK}/p2"

# Build the same kind of standalone arm64-efi loader ROCKNIX uses.  Do not
# depend on BIB's distro shim layout: ABL loads this fallback binary directly,
# and its embedded prefix deterministically selects ESP:/boot/grub/grub.cfg.
GRUB_EFI="${WORK}/bootaa64.efi"
"${GRUB_MKIMAGE}" \
    -O arm64-efi \
    -o "${GRUB_EFI}" \
    -p /boot/grub \
    boot linux ext2 fat squash4 part_msdos part_gpt normal search \
    search_fs_file search_fs_uuid search_label chain reboot loadenv test \
    gfxterm efi_gop
[[ -s "${GRUB_EFI}" ]] || die "grub-mkimage produced an empty arm64 EFI loader"
[[ "$(dd if="${GRUB_EFI}" bs=1 count=2 status=none)" == MZ ]] \
    || die "generated GRUB loader is not a PE/COFF EFI image"
grep -a -q GRUB "${GRUB_EFI}" || die "generated EFI image does not identify as GRUB"
GRUB_EFI_SHA256=$(sha256sum "${GRUB_EFI}" | awk '{print $1}')

LOOP=$(sudo losetup -fP --show "${RAW_IMAGE}")
sleep 1
ESP="${LOOP}p1"
BOOT="${LOOP}p2"
ROOT="${LOOP}p3"

[[ "$(sudo blkid -s TYPE -o value "${ESP}" || true)" == "vfat" ]] \
    || die "${ESP} is not the expected vfat EFI system partition"
[[ "$(sudo blkid -s TYPE -o value "${BOOT}" || true)" == "ext4" ]] \
    || die "${BOOT} is not the expected ext4 /boot partition"
[[ "$(sudo blkid -s TYPE -o value "${ROOT}" || true)" == "btrfs" ]] \
    || die "${ROOT} is not the expected btrfs root partition"

sudo mount "${ESP}" "${WORK}/p1"
P1_MOUNTED=1
sudo mount "${BOOT}" "${WORK}/p2"
P2_MOUNTED=1

[[ -d "${WORK}/p1/EFI" ]] || die "BIB image has no EFI directory"
[[ ! -e "${WORK}/p1/EFI.disabled" ]] || die "EFI was disabled before the RP Mini V2 finalizer ran"
[[ ! -e "${WORK}/p1/KERNEL" ]] || die "stale Android-format /KERNEL found; refusing a mixed boot layout"

sudo mkdir -p "${WORK}/p1/EFI/BOOT"
mapfile -t EFI_LOADERS < <(sudo find "${WORK}/p1/EFI/BOOT" -maxdepth 1 -type f -iname 'bootaa64.efi' -print 2>/dev/null)
[[ ${#EFI_LOADERS[@]} -le 1 ]] \
    || die "ambiguous EFI/BOOT/bootaa64.efi files: ${#EFI_LOADERS[@]}"
if [[ ${#EFI_LOADERS[@]} -eq 1 ]]; then
    EFI_LOADER=${EFI_LOADERS[0]}
    sudo test -s "${EFI_LOADER}" || die "BIB EFI fallback loader is empty"
    [[ ! -e "${EFI_LOADER}.bib-original" ]] \
        || die "unexpected pre-existing EFI loader backup: ${EFI_LOADER}.bib-original"
    sudo cp -- "${EFI_LOADER}" "${EFI_LOADER}.bib-original"
else
    EFI_LOADER="${WORK}/p1/EFI/BOOT/bootaa64.efi"
fi
sudo install -m 0644 "${GRUB_EFI}" "${EFI_LOADER}"
sudo cmp --silent "${GRUB_EFI}" "${EFI_LOADER}" \
    || die "failed to verify the staged standalone GRUB loader"
printf '%s  %s\n' "${GRUB_EFI_SHA256}" "$(basename "${EFI_LOADER}")" \
    | sudo tee "$(dirname "${EFI_LOADER}")/bootaa64.efi.sha256" >/dev/null
(
    cd "$(dirname "${EFI_LOADER}")"
    sudo sha256sum --check --status bootaa64.efi.sha256
) || die "standalone GRUB checksum verification failed"

BLS_DIR="${WORK}/p2/loader/entries"
[[ -d "${BLS_DIR}" ]] || die "active BLS entry directory is missing: ${BLS_DIR}"
mapfile -t BLS_ENTRIES < <(sudo find -L "${BLS_DIR}" -maxdepth 1 -type f -name '*.conf' -print | sort)
[[ ${#BLS_ENTRIES[@]} -gt 0 ]] || die "no BLS entries found"

BLS=""
LOADER_CONF="${WORK}/p2/loader/loader.conf"
if [[ -f "${LOADER_CONF}" ]]; then
    DEFAULT_ENTRY=$(sudo awk '$1=="default" {print $2}' "${LOADER_CONF}")
    if [[ -n "${DEFAULT_ENTRY}" && "${DEFAULT_ENTRY}" != "@saved" ]]; then
        BLS_MATCHES=()
        for candidate in "${BLS_ENTRIES[@]}"; do
            base=$(basename "${candidate}")
            if [[ "${base}" == ${DEFAULT_ENTRY} || "${base}" == ${DEFAULT_ENTRY}.conf ]]; then
                BLS_MATCHES+=("${candidate}")
            fi
        done
        if [[ ${#BLS_MATCHES[@]} -eq 1 ]]; then BLS=${BLS_MATCHES[0]}; fi
    fi
fi
if [[ -z "${BLS}" && ${#BLS_ENTRIES[@]} -eq 1 ]]; then BLS=${BLS_ENTRIES[0]}; fi
[[ -n "${BLS}" ]] || die "could not select one unambiguous default BLS deployment"

bls_one() {
    local key=$1
    local values=()
    mapfile -t values < <(sudo awk -v key="${key}" '$1==key {sub(/^[^[:space:]]+[[:space:]]+/, ""); print}' "${BLS}")
    [[ ${#values[@]} -eq 1 ]] || die "BLS ${BLS} must contain exactly one '${key}' line"
    [[ -n "${values[0]}" ]] || die "BLS '${key}' value is empty"
    printf '%s\n' "${values[0]}"
}

resolve_boot_path() {
    local bls_path=$1
    local relative resolved
    [[ "${bls_path}" == /* ]] || die "BLS path is not absolute: ${bls_path}"
    relative=${bls_path#/boot/}
    relative=${relative#/}
    [[ "/${relative}/" != *"/../"* && "/${relative}/" != *"/./"* ]] \
        || die "unsafe BLS path: ${bls_path}"
    resolved=$(realpath -m -- "${WORK}/p2/${relative}")
    [[ "${resolved}" == "${WORK}/p2/"* ]] || die "BLS path escapes /boot: ${bls_path}"
    printf '%s\n' "${resolved}"
}

LINUX_LINE=$(bls_one linux)
INITRD_LINE=$(bls_one initrd)
OPTIONS_LINE=$(bls_one options)
KERNEL_SOURCE=$(resolve_boot_path "${LINUX_LINE}")
INITRD_SOURCE=$(resolve_boot_path "${INITRD_LINE}")
sudo test -s "${KERNEL_SOURCE}" || die "BLS kernel is missing or empty: ${KERNEL_SOURCE}"
sudo test -s "${INITRD_SOURCE}" || die "BLS initramfs is missing or empty: ${INITRD_SOURCE}"

# Re-assert the internal-storage safety payload from the final deployment, not
# only from the earlier container build log.
INITRAMFS_LIST="${WORK}/initramfs.list"
sudo lsinitrd "${INITRD_SOURCE}" > "${INITRAMFS_LIST}"
for required in \
    usr/bin/bash \
    usr/lib/udev/rules.d/99-armada-rpmini-v2-ufs-readonly.rules \
    usr/libexec/armada/rpmini-v2-ufs-readonly \
    usr/lib/systemd/system/armada-rpmini-v2-ufs-guard.service \
    usr/lib/systemd/system/initrd-root-fs.target.requires/armada-rpmini-v2-ufs-guard.service; do
    grep -Fq "${required}" "${INITRAMFS_LIST}" \
        || die "final initramfs is missing safety payload: ${required}"
done
grep -Eq 'usr/(sbin|bin)/blockdev([[:space:]]|$)' "${INITRAMFS_LIST}" \
    || die "final initramfs is missing blockdev"

verify_initramfs_file() {
    local source=$1 inside=$2 extracted
    extracted="${WORK}/$(basename "${inside}").from-initramfs"
    sudo lsinitrd -f "/${inside}" "${INITRD_SOURCE}" > "${extracted}"
    cmp --silent "${source}" "${extracted}" \
        || die "final initramfs payload differs from reviewed source: ${inside}"
}
verify_initramfs_file \
    "${REPO_ROOT}/system_files/usr/lib/udev/rules.d/99-armada-rpmini-v2-ufs-readonly.rules" \
    usr/lib/udev/rules.d/99-armada-rpmini-v2-ufs-readonly.rules
verify_initramfs_file \
    "${REPO_ROOT}/system_files/usr/libexec/armada/rpmini-v2-ufs-readonly" \
    usr/libexec/armada/rpmini-v2-ufs-readonly
verify_initramfs_file \
    "${REPO_ROOT}/system_files/usr/lib/systemd/system/armada-rpmini-v2-ufs-guard.service" \
    usr/lib/systemd/system/armada-rpmini-v2-ufs-guard.service
grep -Eq '^-rwxr-xr-x .*usr/libexec/armada/rpmini-v2-ufs-readonly$' "${INITRAMFS_LIST}" \
    || die "final initramfs UFS helper is not executable"
grep -F 'usr/lib/systemd/system/initrd-root-fs.target.requires/armada-rpmini-v2-ufs-guard.service -> ../armada-rpmini-v2-ufs-guard.service' \
    "${INITRAMFS_LIST}" >/dev/null \
    || die "final initramfs UFS guard is not required by initrd-root-fs.target"

DEPLOYMENT_DIR=$(dirname "${KERNEL_SOURCE}")
[[ "$(dirname "${INITRD_SOURCE}")" == "${DEPLOYMENT_DIR}" ]] \
    || die "kernel and initramfs came from different BLS deployments"

mapfile -t FDTDIR_LINES < <(sudo awk '$1=="fdtdir" {sub(/^[^[:space:]]+[[:space:]]+/, ""); print}' "${BLS}")
mapfile -t DEVICETREE_LINES < <(sudo awk '$1=="devicetree" {sub(/^[^[:space:]]+[[:space:]]+/, ""); print}' "${BLS}")
if [[ ${#FDTDIR_LINES[@]} -eq 1 && ${#DEVICETREE_LINES[@]} -eq 0 ]]; then
    DTB_SOURCE="$(resolve_boot_path "${FDTDIR_LINES[0]}")/${EXPECTED_DTB_REL}"
elif [[ ${#FDTDIR_LINES[@]} -eq 0 && ${#DEVICETREE_LINES[@]} -eq 1 ]]; then
    [[ "${DEVICETREE_LINES[0]}" == *"/${EXPECTED_DTB_REL}" ]] \
        || die "BLS devicetree is not the exact RP Mini V2 DTB: ${DEVICETREE_LINES[0]}"
    DTB_SOURCE=$(resolve_boot_path "${DEVICETREE_LINES[0]}")
elif [[ ${#FDTDIR_LINES[@]} -eq 0 && ${#DEVICETREE_LINES[@]} -eq 0 ]]; then
    # bootc-image-builder does not always emit fdtdir.  The DTB is still tied
    # unambiguously to BLS by taking it only from that entry's deployment dir.
    DTB_SOURCE="${DEPLOYMENT_DIR}/dtb/${EXPECTED_DTB_REL}"
else
    die "BLS contains an ambiguous fdtdir/devicetree selection"
fi
sudo test -s "${DTB_SOURCE}" || die "exact RP Mini V2 DTB is missing: ${DTB_SOURCE}"

[[ "${DTB_SOURCE}" == "${DEPLOYMENT_DIR}/dtb/${EXPECTED_DTB_REL}" ]] \
    || die "V2 DTB did not come from the selected kernel deployment"

sudo python3 "${VERIFY_ARTIFACTS}" --kernel "${KERNEL_SOURCE}" --dtb "${DTB_SOURCE}"

OSTREE_ARGS=0
for token in ${OPTIONS_LINE}; do
    [[ "${token}" =~ ^[A-Za-z0-9_./:=,@%+-]+$ ]] \
        || die "unsafe or unsupported character in BLS option: ${token}"
    case "${token}" in
        ostree=*) OSTREE_ARGS=$((OSTREE_ARGS + 1)) ;;
        armada.device-target=*) die "BLS already contains a device target marker" ;;
    esac
done
[[ ${OSTREE_ARGS} -eq 1 ]] || die "BLS options must contain exactly one ostree= deployment argument"

BOOT_UUID=$(sudo blkid -s UUID -o value "${BOOT}")
[[ "${BOOT_UUID}" =~ ^[A-Fa-f0-9-]+$ ]] || die "invalid /boot filesystem UUID: ${BOOT_UUID}"

KARGS="${OPTIONS_LINE}"
case " ${KARGS} " in *" video=efifb:off "*) ;; *) KARGS+=" video=efifb:off" ;; esac
KARGS+=" armada.device-target=${DEVICE_TARGET} armada.experimental-boot=1"
for unit in armada-bootimg-sync.service armada-installer-visibility.service \
    bootc-fetch-apply-updates.service bootc-fetch-apply-updates.timer \
    bootloader-update.service; do
    KARGS+=" systemd.mask=${unit}"
done

STAGE_REL="armada/rpmini-v2"
STAGE_DIR="${WORK}/p2/${STAGE_REL}"
NEEDED_KIB=$(sudo du -k "${KERNEL_SOURCE}" "${INITRD_SOURCE}" "${DTB_SOURCE}" | awk '{sum += $1} END {print sum + 65536}')
AVAILABLE_KIB=$(df -Pk "${WORK}/p2" | awk 'NR==2 {print $4}')
[[ "${AVAILABLE_KIB}" =~ ^[0-9]+$ && ${AVAILABLE_KIB} -ge ${NEEDED_KIB} ]] \
    || die "not enough free space on /boot for the staged V2 artifacts"

sudo rm -rf "${STAGE_DIR}"
sudo mkdir -p "${STAGE_DIR}"
sudo install -m 0644 "${KERNEL_SOURCE}" "${STAGE_DIR}/Image"
sudo install -m 0644 "${INITRD_SOURCE}" "${STAGE_DIR}/initramfs.img"
sudo install -m 0644 "${DTB_SOURCE}" "${STAGE_DIR}/${EXPECTED_DTB}"
(
    cd "${STAGE_DIR}"
    sudo sha256sum Image initramfs.img "${EXPECTED_DTB}" | sudo tee SHA256SUMS >/dev/null
)
(
    cd "${STAGE_DIR}"
    sudo sha256sum --check --status SHA256SUMS
) || die "staged V2 boot artifact verification failed"

cat > "${WORK}/grub.cfg" <<EOF
# Generated for Armada's experimental Retroid Pocket Mini V2 SM8250 SD image.
# OTA, Android boot.img synchronization and internal installation are disabled.
# First published image boots a console by default so graphics/session failures
# cannot hide the machine. Select the first entry for the normal Steam session.
set default=1
set timeout=4
set timeout_style=menu
set rotation=270

insmod part_gpt
insmod part_msdos
insmod ext2
search --no-floppy --fs-uuid --set=armada_boot ${BOOT_UUID}

menuentry 'Armada - Retroid Pocket Mini V2 (experimental)' {
    linux (\$armada_boot)/${STAGE_REL}/Image ${KARGS}
    initrd (\$armada_boot)/${STAGE_REL}/initramfs.img
    devicetree (\$armada_boot)/${STAGE_REL}/${EXPECTED_DTB}
}

menuentry 'Armada - Retroid Pocket Mini V2 (diagnostic console)' {
    linux (\$armada_boot)/${STAGE_REL}/Image ${KARGS} systemd.unit=multi-user.target systemd.wants=sshd.service systemd.wants=getty@tty1.service plymouth.enable=0 loglevel=7
    initrd (\$armada_boot)/${STAGE_REL}/initramfs.img
    devicetree (\$armada_boot)/${STAGE_REL}/${EXPECTED_DTB}
}
EOF

install_grub_config() {
    local destination=$1
    sudo mkdir -p "$(dirname "${destination}")"
    if [[ -f "${destination}" && ! -f "${destination}.bib-original" ]]; then
        sudo cp -- "${destination}" "${destination}.bib-original"
    fi
    sudo install -m 0644 "${WORK}/grub.cfg" "${destination}"
    sudo cmp --silent "${WORK}/grub.cfg" "${destination}" \
        || die "failed to verify staged GRUB config: ${destination}"
}

# Fedora GRUB follows the p2 /grub2 path through its vendor stub; ROCKNIX GRUB
# embeds /boot/grub on the ESP.  Stage both plus the standard fallback location.
install_grub_config "${WORK}/p2/grub2/grub.cfg"
install_grub_config "${WORK}/p1/boot/grub/grub.cfg"
install_grub_config "${WORK}/p1/EFI/BOOT/grub.cfg"

MARKER="${WORK}/device-target"
cat > "${MARKER}" <<EOF
ARMADA_DEVICE_TARGET=${DEVICE_TARGET}
ARMADA_SOC=SM8250
ARMADA_BOOT_PATH=existing-rocknix-abl-efi-grub
ARMADA_DTB=${EXPECTED_DTB_REL}
ARMADA_GRUB_SHA256=${GRUB_EFI_SHA256}
ARMADA_ABL_PAYLOAD=not-included
ARMADA_OTA=disabled
ARMADA_INTERNAL_INSTALLER=disabled
EOF
sudo install -m 0644 "${MARKER}" "${WORK}/p1/.armada-device-target"
sudo install -m 0644 "${MARKER}" "${STAGE_DIR}/device-target"

sudo sync
sudo umount "${WORK}/p2"
P2_MOUNTED=0
sudo umount "${WORK}/p1"
P1_MOUNTED=0
sudo fatlabel "${ESP}" ARMADA

# Match the proven Armada SD-card layout: MBR avoids a backup GPT stranded in
# the middle of a larger flashed card and remains visible to Android vold.
TABLE=$(sudo sfdisk -J "${LOOP}")
mapfile -t PARTS < <(jq -r '.partitiontable.partitions[] | "\(.start) \(.size)"' <<<"${TABLE}")
[[ ${#PARTS[@]} -eq 3 ]] || die "expected exactly three BIB partitions"
read -r P1_START P1_SIZE <<<"${PARTS[0]}"
read -r P2_START P2_SIZE <<<"${PARTS[1]}"
read -r P3_START P3_SIZE <<<"${PARTS[2]}"
SECTORS=$(sudo blockdev --getsz "${LOOP}")
[[ "$(jq -r '.partitiontable.sectorsize // 512' <<<"${TABLE}")" == 512 ]] \
    || die "non-512-byte sector layout is unsupported"
[[ ${P1_START} -ge 34 ]] || die "p1 overlaps the primary GPT span"
[[ $((P3_START + P3_SIZE)) -le $((SECTORS - 33)) ]] || die "p3 overlaps the backup GPT span"

sudo dd if=/dev/zero of="${LOOP}" bs=512 seek=1 count=33 conv=notrunc status=none
sudo dd if=/dev/zero of="${LOOP}" bs=512 seek=$((SECTORS - 33)) count=33 conv=notrunc status=none
sudo sfdisk --label dos "${LOOP}" <<EOF
${P1_START},${P1_SIZE},c,*
${P2_START},${P2_SIZE},da
${P3_START},${P3_SIZE},da
EOF
POST_TABLE=$(sudo sfdisk -J "${LOOP}")
mapfile -t POST_PARTS < <(jq -r \
    '.partitiontable.partitions[] | "\(.start) \(.size) \(.type) \(.bootable // false)"' \
    <<<"${POST_TABLE}")
[[ "$(jq -r '.partitiontable.label' <<<"${POST_TABLE}")" == dos \
    && ${#POST_PARTS[@]} -eq 3 ]] || die "MBR conversion verification failed"
read -r POST_P1_START POST_P1_SIZE POST_P1_TYPE POST_P1_BOOT <<<"${POST_PARTS[0]}"
read -r POST_P2_START POST_P2_SIZE POST_P2_TYPE POST_P2_BOOT <<<"${POST_PARTS[1]}"
read -r POST_P3_START POST_P3_SIZE POST_P3_TYPE POST_P3_BOOT <<<"${POST_PARTS[2]}"
case ${POST_P1_TYPE} in c|0c|0x0c) ;; *) die "unexpected MBR p1 type: ${POST_P1_TYPE}" ;; esac
case ${POST_P2_TYPE} in da|0xda) ;; *) die "unexpected MBR p2 type: ${POST_P2_TYPE}" ;; esac
case ${POST_P3_TYPE} in da|0xda) ;; *) die "unexpected MBR p3 type: ${POST_P3_TYPE}" ;; esac
[[ ${POST_P1_START} == "${P1_START}" && ${POST_P1_SIZE} == "${P1_SIZE}" \
    && ${POST_P2_START} == "${P2_START}" && ${POST_P2_SIZE} == "${P2_SIZE}" \
    && ${POST_P3_START} == "${P3_START}" && ${POST_P3_SIZE} == "${P3_SIZE}" \
    && ${POST_P1_BOOT} == true && ${POST_P2_BOOT} == false && ${POST_P3_BOOT} == false ]] \
    || die "MBR partition geometry, type, or boot flag changed unexpectedly"

sudo losetup -d "${LOOP}"
LOOP=""

GZIP_LEVEL="${GZIP_LEVEL:-6}"
[[ "${GZIP_LEVEL}" =~ ^[1-9]$ ]] || die "GZIP_LEVEL must be 1 through 9"
mkdir -p "$(dirname "${OUT}")"
THREADS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
pigz -f "-${GZIP_LEVEL}" -p "${THREADS}" -c "${RAW_IMAGE}" > "${OUT}"
[[ -s "${OUT}" ]] || die "compressed output is empty"
rm -f "${RAW_IMAGE}"

echo "Built dedicated RP Mini V2 image: ${OUT}"
echo "Boot chain: existing working SM8250 ROCKNIX ABL -> EFI/GRUB -> raw Image + ${EXPECTED_DTB}"
echo "No ABL flasher or payload is included in this first SD-only image."
echo "OTA, Android boot.img synchronization, and internal installation are disabled."
