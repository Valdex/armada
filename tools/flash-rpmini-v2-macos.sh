#!/usr/bin/env bash
# Flash only the exact 256 GB card observed in the RP Mini V2 baseline.
set -euo pipefail

readonly EXPECTED_CARD_BYTES=256355860480
readonly CONFIRM_FLAG=--write-exact-rpmini-256gb-card

usage() {
    cat <<'EOF'
Usage: flash-rpmini-v2-macos.sh IMAGE.img.gz /dev/diskN \
       --write-exact-rpmini-256gb-card

The destination must be a whole, physical, external, removable macOS disk
whose exact capacity is 256355860480 bytes. Internal disks, partitions, other
256 GB cards, and the protected 1 TB card are rejected.
EOF
}

[[ $(uname -s) == Darwin ]] || {
    echo "ERROR: this guard is for macOS only" >&2
    exit 1
}
[[ $# -eq 3 && $3 == "${CONFIRM_FLAG}" ]] || { usage >&2; exit 2; }

image=$1
disk=$2
[[ ${image} == *.img.gz && -f ${image} ]] || {
    echo "ERROR: missing dedicated .img.gz artifact: ${image}" >&2
    exit 1
}
[[ ${disk} =~ ^/dev/disk[0-9]+$ ]] || {
    echo "ERROR: destination must be one whole /dev/diskN device" >&2
    exit 1
}

for command in diskutil gzip plutil shasum sudo; do
    command -v "${command}" >/dev/null || {
        echo "ERROR: required command is missing: ${command}" >&2
        exit 1
    }
done

checksum=${image}.sha256
[[ -f ${checksum} ]] || {
    echo "ERROR: checksum is missing: ${checksum}" >&2
    exit 1
}
(
    cd "$(dirname "${image}")"
    shasum -a 256 --check "$(basename "${checksum}")"
)
gzip -t "${image}"

info=$(mktemp)
cleanup() { rm -f "${info}"; }
trap cleanup EXIT INT TERM

read_disk_info() {
    diskutil info -plist "${disk}" > "${info}"
    whole=$(plutil -extract Whole raw -o - "${info}")
    internal=$(plutil -extract Internal raw -o - "${info}")
    removable=$(plutil -extract RemovableMedia raw -o - "${info}")
    physical=$(plutil -extract VirtualOrPhysical raw -o - "${info}")
    total_bytes=$(plutil -extract TotalSize raw -o - "${info}")
    device_node=$(plutil -extract DeviceNode raw -o - "${info}")

    [[ ${whole} == true && ${internal} == false && ${removable} == true \
        && ${physical} == Physical && ${device_node} == "${disk}" \
        && ${total_bytes} == "${EXPECTED_CARD_BYTES}" ]] || {
        echo "ERROR: destination is not the exact protected-scope 256 GB removable card" >&2
        exit 1
    }
}

read_disk_info
raw_disk=/dev/r${disk#/dev/}
[[ -c ${raw_disk} ]] || {
    echo "ERROR: raw destination is unavailable: ${raw_disk}" >&2
    exit 1
}

raw_size=$(gzip -dc "${image}" | wc -c | tr -d '[:space:]')
raw_sha256=$(gzip -dc "${image}" | shasum -a 256 | awk '{print $1}')
[[ ${raw_size} =~ ^[0-9]+$ && ${raw_size} -gt 1073741824 \
    && ${raw_size} -lt ${EXPECTED_CARD_BYTES} ]] || {
    echo "ERROR: uncompressed image size is implausible: ${raw_size}" >&2
    exit 1
}

sudo -n true || {
    echo "ERROR: sudo authentication is required before unattended flashing" >&2
    exit 1
}
diskutil unmountDisk "${disk}"
read_disk_info

echo "Writing verified RP Mini V2 image to the exact 256 GB removable card..."
gzip -dc "${image}" | sudo -n dd of="${raw_disk}" bs=4m
sync

readback_sha256=$(sudo -n head -c "${raw_size}" "${raw_disk}" | shasum -a 256 | awk '{print $1}')
[[ ${readback_sha256} == "${raw_sha256}" ]] || {
    echo "ERROR: full post-write readback hash mismatch" >&2
    exit 1
}

diskutil eject "${disk}"
echo "PASS: exact 256 GB RP Mini card written and fully verified"
