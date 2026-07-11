#!/usr/bin/env bash
# Native-aarch64 Podman wrapper for scripts/build-kernel.sh.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${ROOT}/BASE.env"

command -v podman >/dev/null || { echo 'ERROR: podman is required' >&2; exit 1; }
[[ $(uname -m) == arm64 || $(uname -m) == aarch64 ]] || {
    echo 'ERROR: use an arm64 host or the ubuntu-24.04-arm workflow' >&2
    exit 1
}

mkdir -p "${ROOT}/out" "${ROOT}/.ccache"
rm -f "${ROOT}"/out/armada-kernel-*.tar.zst "${ROOT}"/out/armada-kernel-*.tar.zst.sha256

mounts=(
    -v "${ROOT}:/work:Z"
    -v "${ROOT}/.ccache:/ccache:Z"
)
container_source=
if [[ -n ${ROCKNIX_SOURCE:-} ]]; then
    mounts+=( -v "$(realpath "${ROCKNIX_SOURCE}"):/rocknix:ro,Z" )
    container_source=/rocknix
fi

podman run --rm \
    --platform linux/arm64 \
    "${mounts[@]}" \
    -e CCACHE_DIR=/ccache \
    -e CCACHE_MAXSIZE=4G \
    -e ROCKNIX_SOURCE="${container_source}" \
    -w /work \
    "${BUILDER_IMAGE}" \
    bash -euxc '
        dnf -y install gcc binutils make bc bison flex openssl-devel \
            elfutils-libelf-devel zstd xz cpio patch curl git perl-interpreter \
            python3 findutils diffutils gawk grep sed coreutils hostname gzip \
            tar ccache rsync kmod
        export PATH="/usr/lib64/ccache:${PATH}"
        WORK_DIR=/tmp/armada-rpmini-v2-kernel OUT_DIR=/work/out \
            /work/scripts/build-kernel.sh
    '
