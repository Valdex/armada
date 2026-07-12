ARG FEX_PKG=ghcr.io/virtudude/armada-packages/fex@sha256:5efff7dd05124e0653fd31a62bba78a68c87bd28f54ad12f6d0079acb3f07f7e
ARG MESA_PKG=ghcr.io/virtudude/armada-packages/mesa@sha256:00f45355cd5259413ec7463c9accaf69858e8472558441095883fc5ad71fd1a9
ARG MANGOHUD_PKG=ghcr.io/virtudude/armada-packages/mangohud@sha256:685ec69671d23188cfaf93a9d898da2356eca2ee80d3205a7445b200c6774c47
ARG GAMESCOPE_PKG=ghcr.io/virtudude/armada-packages/gamescope@sha256:220e6615567be4fe79324fb5a77247a1ddaefcc6c74ebb3dcd39c9bd3e54794e
ARG KERNEL_PKG=ghcr.io/virtudude/armada-packages/kernel@sha256:cf04405dda5111b91cd24bcb71985357ab38ecf5c6afe5bc34bc878482f3398e
ARG INPUTPLUMBER_PKG=ghcr.io/virtudude/armada-packages/inputplumber@sha256:25c33d833a9323d582371869c3422026ac5ab71c611b7b6c863aa3ea92c3140d
ARG EXTEST_PKG=ghcr.io/virtudude/armada-packages/extest@sha256:bdd44824ebbff167e007fd44df794713e2340e8fe94247d9e231f3ce10ff1844
ARG NETWORKMANAGER_PKG=ghcr.io/virtudude/armada-packages/networkmanager@sha256:ed0b1c9877fbeba38067f3b0de663c9483000019e0a0a968740f231bcfe3d095
ARG JUPITER_HW_SUPPORT_PKG=ghcr.io/virtudude/armada-packages/jupiter-hw-support@sha256:3d555f9d9ac79e7fbca2e59a45df97782fb5bee7ce3f65613703122b93b8a866

FROM ${FEX_PKG} AS fex
FROM ${MESA_PKG} AS mesa
FROM ${MANGOHUD_PKG} AS mangohud
FROM ${GAMESCOPE_PKG} AS gamescope
FROM ${KERNEL_PKG} AS kernel
FROM ${INPUTPLUMBER_PKG} AS inputplumber
FROM ${NETWORKMANAGER_PKG} AS networkmanager
FROM ${JUPITER_HW_SUPPORT_PKG} AS jupiter-hw-support
FROM ${EXTEST_PKG} AS extest

# SSC gyro daemons (see sensors-ssc/README.md): adsprpcd from pinned
# qualcomm/fastrpc + the single-file snsfeed QRTR client.
FROM registry.fedoraproject.org/fedora:44 AS sensors-build
ARG FASTRPC_COMMIT=706071caca54b9a56d78793c30d04351de5fbd96
ARG FASTRPC_SHA256=14aa4dbd0a69af319d7cca091a72316d68ecc36d4ff2906b75701ddcfd94b6b9
RUN dnf -y install --setopt=install_weak_deps=False gcc make tar gzip && dnf clean all
WORKDIR /build
COPY sensors-ssc/ /build/sensors-ssc/
RUN curl -fL -o fastrpc.tar.gz "https://github.com/qualcomm/fastrpc/archive/${FASTRPC_COMMIT}.tar.gz" && \
    echo "${FASTRPC_SHA256}  fastrpc.tar.gz" | sha256sum -c && \
    tar xzf fastrpc.tar.gz && \
    cd "fastrpc-${FASTRPC_COMMIT}" && \
    cp /build/sensors-ssc/bsd_shim.c /build/sensors-ssc/daemon_main.c /build/sensors-ssc/snsfeed.c src/ && \
    FASTRPC_CFLAGS="-O2 -Iinc -Isrc -Isrc/dspqueue -DLE_ENABLE -DUSE_SYSLOG -fPIC -w" && \
    FASTRPC_SRC="fastrpc_apps_user.c fastrpc_perf.c fastrpc_pm.c fastrpc_config.c \
      fastrpc_mem.c fastrpc_notif.c fastrpc_ioctl.c fastrpc_log.c fastrpc_procbuf.c \
      fastrpc_cap.c log_config.c dspsignal.c dspqueue/dspqueue_cpu.c \
      dspqueue/dspqueue_rpc_stub.c listener_android.c apps_std_imp.c apps_mem_imp.c \
      apps_mem_skel.c rpcmem_linux.c adspmsgd.c adspmsgd_printf.c std_path.c \
      std_dtoa.c BufBound.c platform_libs.c pl_list.c gpls.c remotectl_stub.c \
      remotectl1_stub.c adspmsgd_apps_skel.c adspmsgd_adsp_stub.c \
      adspmsgd_adsp1_stub.c apps_remotectl_skel.c adsp_current_process_stub.c \
      adsp_current_process1_stub.c adsp_listener_stub.c adsp_listener1_stub.c \
      apps_std_skel.c adsp_perf_stub.c adsp_perf1_stub.c mod_table.c \
      fastrpc_context.c adsp_default_listener.c adsp_default_listener_stub.c \
      adsp_default_listener1_stub.c" && \
    objs="" && \
    for s in ${FASTRPC_SRC} bsd_shim.c daemon_main.c; do \
      o="src/$(echo ${s} | tr '/' '_').o"; \
      gcc ${FASTRPC_CFLAGS} -c "src/${s}" -o "${o}"; \
      objs="${objs} ${o}"; \
    done && \
    gcc -O2 -o adsprpcd ${objs} -ldl -lm -lpthread && \
    gcc -O2 -o snsfeed src/snsfeed.c -lm && \
    mkdir -p /out && cp adsprpcd snsfeed /out/

FROM docker.io/library/node:22-slim AS decky-build
WORKDIR /build
COPY decky/armada-control/package.json decky/armada-control/package-lock.json ./
RUN npm ci
COPY decky/armada-control/ ./
RUN npm run build

FROM scratch AS ctx
COPY build_files /build_files/
COPY decky /decky/
COPY system_files /system_files/

FROM quay.io/fedora/fedora-bootc:44
ARG ARMADA_VERSION=unknown
ARG ARMADA_DEVICE_TARGET=universal
LABEL org.opencontainers.image.version="${ARMADA_VERSION}"
LABEL org.armada.device-target="${ARMADA_DEVICE_TARGET}"

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=fex,source=/rpms,target=/packages/fex \
    --mount=type=bind,from=mesa,source=/rpms,target=/packages/mesa \
    --mount=type=bind,from=mangohud,source=/rpms,target=/packages/mangohud \
    --mount=type=bind,from=gamescope,source=/rpms,target=/packages/gamescope \
    --mount=type=bind,from=kernel,source=/kernel,target=/packages/kernel \
    --mount=type=bind,from=inputplumber,source=/rpms,target=/packages/inputplumber \
    --mount=type=bind,from=networkmanager,source=/rpms,target=/packages/networkmanager \
    --mount=type=bind,from=jupiter-hw-support,source=/rpms,target=/packages/jupiter-hw-support \
    --mount=type=bind,from=extest,source=/,target=/packages/extest \
    --mount=type=bind,from=sensors-build,source=/out,target=/packages/rpmini-sensors \
    --mount=type=bind,from=decky-build,source=/build/dist,target=/packages/decky-dist \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    mkdir -p /usr/lib/armada && \
    printf '%s\n' "${ARMADA_VERSION}" >/usr/lib/armada/version && \
    printf '%s\n' "${ARMADA_DEVICE_TARGET}" >/usr/lib/armada/build-target && \
    /ctx/build_files/build.sh

RUN bootc container lint
