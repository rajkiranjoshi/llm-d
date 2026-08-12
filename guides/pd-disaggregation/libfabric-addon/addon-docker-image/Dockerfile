# Builds the NIXL LIBFABRIC backend plugin (libplugin_LIBFABRIC.so) and
# AWS EFA-enabled libfabric, producing a minimal "addon" image that can
# be used as an init container to inject EFA/LIBFABRIC support into the
# RHAIIS vllm-cuda-rhel9 image.
#
# Target: registry.stage.redhat.io/rhaii/vllm-cuda-rhel9:3.5.0-*
#   - RHEL 9.6 / x86_64
#   - GCC 11.5
#   - CUDA 13.0
#   - NIXL v1.2.0
#   - System libfabric 1.22.0 (no EFA provider)
#
# This build produces:
#   /artifacts/plugins/libplugin_LIBFABRIC.so   — NIXL backend plugin
#   /artifacts/plugins/libplugin_{UCX,GDS,GDS_MT,POSIX}.so — existing NIXL plugins
#   /artifacts/efa/lib/libfabric.*              — EFA-enabled libfabric (AWS fork)
#   /artifacts/efa/bin/fi_info                  — libfabric introspection tool
#   /artifacts/abseil/lib/libabsl_*.so          — abseil-cpp shared libs (NIXL runtime dep)
#
# Prerequisites:
#   - RHEL entitlement certs in entitlement/ and rhsm-ca/ (see rhel-subscription-setup.md)
#   - Logged into registry.stage.redhat.io
#
# Usage:
#   cp build.env.example build.env   # configure base image, cert paths, output tag
#   ./build.sh                       # builds using build.env

# --------------------------------------------------------------------------
# Versions — pinned to match llm-d v0.8.1 (EFA image) + RHAIIS 3.5.0
# --------------------------------------------------------------------------
ARG NIXL_VERSION=v1.2.0
ARG EFA_INSTALLER_VERSION=1.46.0
ARG AWS_LIBFABRIC_VERSION=v2.3.1amzn4.0

# Use the RHAIIS target image as builder base — guarantees identical
# GCC, glibc, CUDA, libstdc++, and NIXL shared libraries.
# Requires RHEL entitlement certs for dnf install (see rhel-subscription-setup.md).
ARG BASE_IMAGE=registry.stage.redhat.io/rhaii/vllm-cuda-rhel9:3.5.0-1784900545

# ============================================================================
# Stage 1: Build EFA-enabled libfabric from AWS fork
# ============================================================================
FROM ${BASE_IMAGE} AS libfabric-builder

ARG AWS_LIBFABRIC_VERSION

USER root

COPY entitlement/ /run/secrets/etc-pki-entitlement/
COPY rhsm-ca/ /etc/rhsm/ca/

# The subscription-manager dnf plugin actively disables repos when it
# doesn't detect a valid registration (container mode doesn't activate
# during podman build). Disable the plugin, inject entitlement cert
# paths into the existing repo definitions, and let dnf use them directly.
RUN sed -i 's/enabled\s*=\s*1/enabled=0/' /etc/dnf/plugins/subscription-manager.conf && \
    sed -i 's/enabled\s*=\s*1/enabled=0/' /etc/dnf/plugins/product-id.conf && \
    CERT=$(find /run/secrets/etc-pki-entitlement -name '*.pem' ! -name '*-key.pem' | head -1) && \
    KEY=$(find /run/secrets/etc-pki-entitlement -name '*-key.pem' | head -1) && \
    sed -i "/^sslcacert/a sslclientcert = $CERT\nsslclientkey = $KEY" /etc/yum.repos.d/redhat.repo && \
    sed -i 's/${releasever_major}/9/g' /etc/yum.repos.d/cuda.repo && \
    dnf install -y \
    gcc gcc-c++ make automake autoconf libtool \
    rdma-core-devel \
    && dnf install -y --enablerepo='external-nvidia-cuda-for-rhel-9-x86_64-rpms' \
    cuda-nvml-devel-13-0 \
    && dnf clean all \
    && rm -rf /run/secrets/etc-pki-entitlement

WORKDIR /build

# Create a stub libnvidia-ml.so for the linker (the real library is
# injected by the NVIDIA device plugin at runtime, not at build time)
RUN printf '%s\n' \
    'int nvmlInit(void){return 0;}' \
    'int nvmlInit_v2(void){return 0;}' \
    'int nvmlShutdown(void){return 0;}' \
    'int nvmlDeviceGetCount_v2(void *c){return 0;}' \
    'int nvmlDeviceGetHandleByIndex_v2(unsigned int i,void *d){return 0;}' \
    'int nvmlDeviceGetPciInfo_v3(void *d,void *p){return 0;}' \
    | gcc -shared -o /usr/lib64/libnvidia-ml.so -x c -

RUN git clone --depth 1 --branch ${AWS_LIBFABRIC_VERSION} \
    https://github.com/aws/libfabric.git && \
    cd libfabric && \
    ./autogen.sh && \
    ./configure \
        --prefix=/opt/libfabric-efa \
        --enable-efa \
        --enable-verbs \
        --enable-shm \
        --enable-tcp \
        --enable-rxm \
        --enable-rxd \
        --enable-mrail \
        --with-cuda=/usr/local/cuda \
        --disable-static && \
    make -j$(nproc) && \
    make install

# ============================================================================
# Stage 2: Build NIXL LIBFABRIC plugin against EFA libfabric
# ============================================================================
FROM ${BASE_IMAGE} AS nixl-builder

ARG NIXL_VERSION

USER root

COPY entitlement/ /run/secrets/etc-pki-entitlement/
COPY rhsm-ca/ /etc/rhsm/ca/

RUN sed -i 's/enabled\s*=\s*1/enabled=0/' /etc/dnf/plugins/subscription-manager.conf && \
    sed -i 's/enabled\s*=\s*1/enabled=0/' /etc/dnf/plugins/product-id.conf && \
    CERT=$(find /run/secrets/etc-pki-entitlement -name '*.pem' ! -name '*-key.pem' | head -1) && \
    KEY=$(find /run/secrets/etc-pki-entitlement -name '*-key.pem' | head -1) && \
    sed -i "/^sslcacert/a sslclientcert = $CERT\nsslclientkey = $KEY" /etc/yum.repos.d/redhat.repo && \
    dnf install -y \
    gcc gcc-c++ \
    ninja-build cmake pkg-config \
    hwloc-devel numactl-devel \
    rdma-core-devel \
    && pip install meson pybind11 \
    && dnf clean all \
    && rm -rf /run/secrets/etc-pki-entitlement

RUN printf '%s\n' \
    'int nvmlInit(void){return 0;}' \
    'int nvmlInit_v2(void){return 0;}' \
    'int nvmlShutdown(void){return 0;}' \
    'int nvmlDeviceGetCount_v2(void *c){return 0;}' \
    'int nvmlDeviceGetHandleByIndex_v2(unsigned int i,void *d){return 0;}' \
    'int nvmlDeviceGetPciInfo_v3(void *d,void *p){return 0;}' \
    | gcc -shared -o /usr/lib64/libnvidia-ml.so -x c -

# abseil-cpp: build shared libraries from source (the RHAIIS image has no
# abseil; the libs will be copied into the addon and injected at runtime)
RUN cd /tmp && \
    git clone --depth 1 --branch 20240116.2 https://github.com/abseil/abseil-cpp.git && \
    cd abseil-cpp && \
    cmake -B build -DCMAKE_INSTALL_PREFIX=/usr/local \
          -DCMAKE_INSTALL_LIBDIR=lib64 \
          -DCMAKE_CXX_STANDARD=17 -DABSL_PROPAGATE_CXX_STD=ON \
          -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DABSL_BUILD_TESTING=OFF \
          -DBUILD_SHARED_LIBS=ON && \
    cmake --build build -j$(nproc) && \
    cmake --install build && \
    ldconfig && \
    rm -rf /tmp/abseil-cpp

# Copy EFA-enabled libfabric from stage 1
COPY --from=libfabric-builder /opt/libfabric-efa /opt/libfabric-efa

WORKDIR /build

RUN git clone --depth 1 --branch ${NIXL_VERSION} \
    https://github.com/ai-dynamo/nixl.git && \
    cd nixl && \
    meson setup build \
        --prefix=/opt/nixl-build \
        -Dbuildtype=release \
        -Dlibfabric_path=/opt/libfabric-efa \
        -Denable_plugins=LIBFABRIC \
        -Dinstall_headers=false \
        -Dbuild_tests=false \
        -Dbuild_examples=false && \
    cd build && \
    ninja src/plugins/libfabric/libplugin_LIBFABRIC.so

# ============================================================================
# Stage 3: Assemble minimal addon image with just the artifacts
# ============================================================================
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.6 AS addon

RUN mkdir -p /artifacts/plugins /artifacts/efa/lib /artifacts/efa/bin /artifacts/abseil/lib

# NIXL LIBFABRIC plugin
COPY --from=nixl-builder \
    /build/nixl/build/src/plugins/libfabric/libplugin_LIBFABRIC.so \
    /artifacts/plugins/

# Existing NIXL plugins from the base image (so volume mount doesn't hide them)
COPY --from=nixl-builder \
    /opt/app-root/lib/python3.12/site-packages/.nixl_cu13.mesonpy.libs/plugins/ \
    /artifacts/plugins/

# Abseil shared libraries (required by libplugin_LIBFABRIC.so at runtime;
# the RHAIIS image does not ship abseil)
COPY --from=nixl-builder /usr/local/lib64/ /tmp/abseil-all/
RUN cp /tmp/abseil-all/libabsl_*.so* /artifacts/abseil/lib/ && \
    rm -rf /tmp/abseil-all

# EFA-enabled libfabric shared libraries
COPY --from=libfabric-builder /opt/libfabric-efa/lib/ /artifacts/efa/lib/
COPY --from=libfabric-builder /opt/libfabric-efa/bin/fi_info /artifacts/efa/bin/

COPY inject.sh /artifacts/inject.sh

ENTRYPOINT ["/bin/sh", "-c"]
CMD ["echo 'Use as init container — see README.md'"]
