ARG FEX_PKG=ghcr.io/virtudude/armada-packages/fex@sha256:db24aa032c986e595427b8bba668d0201fe9dc9176cae6050c4137113a06c3c0
ARG MESA_PKG=ghcr.io/virtudude/armada-packages/mesa@sha256:02508c22812d47b052378c655129c0847066b19473b142876a403913189d5c8e
ARG MANGOHUD_PKG=ghcr.io/virtudude/armada-packages/mangohud@sha256:dd24d0259b627b7ba12a34683f782289bec31f286fdb58bc066c7374800d6a1d
ARG GAMESCOPE_PKG=ghcr.io/virtudude/armada-packages/gamescope@sha256:d2e4f3125e1d889665671c69bfab3662474d0fcdca9aeeed58e00ceeb8a97e2a
ARG KERNEL_PKG=ghcr.io/virtudude/armada-packages/kernel@sha256:6035eae3c84c0a3dbffc3a1aabd5a9cf78d88c70612c933bb5990ade85a906dc
ARG INPUTPLUMBER_PKG=ghcr.io/virtudude/armada-packages/inputplumber@sha256:1df4f9fc74dbb41c7ebe33bb6934745a4ab01c002178ae2bd34e7e99cebafd35
ARG EXTEST_PKG=ghcr.io/virtudude/armada-packages/extest@sha256:3b0d047706d5f3398972d433f0b76f6f2d953bf52383a428857ede13cc16a109

FROM ${FEX_PKG} AS fex
FROM ${MESA_PKG} AS mesa
FROM ${MANGOHUD_PKG} AS mangohud
FROM ${GAMESCOPE_PKG} AS gamescope
FROM ${KERNEL_PKG} AS kernel
FROM ${INPUTPLUMBER_PKG} AS inputplumber
FROM ${EXTEST_PKG} AS extest

FROM scratch AS ctx
COPY build_files /build_files/
COPY system_files /system_files/

FROM quay.io/fedora/fedora-bootc:44

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=fex,source=/rpms,target=/packages/fex \
    --mount=type=bind,from=mesa,source=/rpms,target=/packages/mesa \
    --mount=type=bind,from=mangohud,source=/rpms,target=/packages/mangohud \
    --mount=type=bind,from=gamescope,source=/rpms,target=/packages/gamescope \
    --mount=type=bind,from=kernel,source=/kernel,target=/packages/kernel \
    --mount=type=bind,from=inputplumber,source=/rpms,target=/packages/inputplumber \
    --mount=type=bind,from=extest,source=/,target=/packages/extest \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build_files/build.sh

RUN bootc container lint
