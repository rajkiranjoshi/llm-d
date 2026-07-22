#!/usr/bin/env bash
# Build nixlbench inside a running llm-d-aws pod.
#
# llm-d-aws:v0.8.1 ships NIXL as a Python wheel (nixl==1.2.0) under /opt/vllm —
# runtime .so + plugins, but no C++ headers /opt/nixl tree. This script:
#   1) discovers wheel libs (prefer CUDA 12)
#   2) clones matching NIXL sources for headers + nixlbench
#   3) stages a link prefix and builds only benchmark/nixlbench
set -euo pipefail

NIXL_GIT_REF="${NIXL_GIT_REF:-v1.2.0}"
NIXL_REPO="${NIXL_REPO:-https://github.com/ai-dynamo/nixl.git}"
ETCD_CPP_REPO="${ETCD_CPP_REPO:-https://github.com/etcd-cpp-apiv3/etcd-cpp-apiv3.git}"
WORKDIR="${WORKDIR:-/tmp/nixlbench-build}"
NIXL_LINK_PREFIX="${NIXL_LINK_PREFIX:-/opt/nixl-for-bench}"
NIXLBENCH_PREFIX="${NIXLBENCH_PREFIX:-/usr/local/nixlbench}"
INSTALL_MARKER="${INSTALL_MARKER:-/usr/local/nixlbench/.install-complete}"

log() { echo "[install-nixlbench] $*"; }
die() { echo "[install-nixlbench] ERROR: $*" >&2; exit 1; }

export PATH="/opt/amazon/efa/bin:/opt/ucx/bin:/usr/local/bin:/opt/vllm/bin:${PATH}"

if [[ -x "${NIXLBENCH_PREFIX}/bin/nixlbench" && -f "${INSTALL_MARKER}" ]]; then
  log "nixlbench already installed at ${NIXLBENCH_PREFIX}/bin/nixlbench"
  "${NIXLBENCH_PREFIX}/bin/nixlbench" --help >/dev/null
  exit 0
fi

# --- discover NIXL runtime libs from the wheel ---
discover_nixl_lib_dir() {
  local d
  for d in \
    /opt/vllm/lib/python3.12/site-packages/.nixl_cu12.mesonpy.libs \
    /opt/vllm/lib64/python3.12/site-packages/.nixl_cu12.mesonpy.libs \
    /opt/vllm/lib/python3.12/site-packages/.nixl_cu13.mesonpy.libs \
    /opt/vllm/lib64/python3.12/site-packages/.nixl_cu13.mesonpy.libs \
    /opt/nixl/lib64 \
    /opt/nixl/lib \
    /usr/lib64
  do
    if [[ -e "${d}/libnixl.so" ]]; then
      echo "${d}"
      return 0
    fi
  done
  return 1
}

discover_nixl_extra_lib_dir() {
  # absl / bundled deps next to the wheel
  local d
  for d in \
    /opt/vllm/lib/python3.12/site-packages/nixl_cu12.libs \
    /opt/vllm/lib64/python3.12/site-packages/nixl_cu12.libs \
    /opt/vllm/lib/python3.12/site-packages/nixl_cu13.libs \
    /opt/vllm/lib64/python3.12/site-packages/nixl_cu13.libs
  do
    if [[ -d "${d}" ]]; then
      echo "${d}"
      return 0
    fi
  done
  return 1
}

log "Discovering NIXL libraries from image..."
NIXL_LIB_DIR="$(discover_nixl_lib_dir)" || die "libnixl.so not found (expected under /opt/vllm ... mesonpy.libs)"
NIXL_EXTRA_LIB_DIR="$(discover_nixl_extra_lib_dir || true)"
log "NIXL libs:       ${NIXL_LIB_DIR}"
log "NIXL extra libs: ${NIXL_EXTRA_LIB_DIR:-<none>}"

export LD_LIBRARY_PATH="${NIXL_LIB_DIR}:${NIXL_EXTRA_LIB_DIR:-}:/opt/amazon/efa/lib64:/opt/amazon/efa/lib:/opt/ucx/lib64:/opt/ucx/lib:/usr/local/lib64:/usr/local/lib:/usr/lib64:${LD_LIBRARY_PATH:-}"

# --- package deps (UBI9 / RHEL) ---
install_build_deps() {
  local PKG
  if command -v dnf >/dev/null 2>&1; then
    PKG=dnf
  elif command -v microdnf >/dev/null 2>&1; then
    PKG=microdnf
  elif command -v yum >/dev/null 2>&1; then
    PKG=yum
  else
    die "no dnf/yum found; cannot install build dependencies"
  fi

  log "Installing build dependencies via ${PKG} (best-effort per package)..."
  # Install packages individually so one missing name (e.g. boost-devel on UBI)
  # does not abort the whole transaction (which previously skipped cmake).
  local pkg
  for pkg in \
    git gcc-c++ make cmake ninja-build pkgconfig \
    openssl-devel \
    gflags-devel libgomp \
    libcurl-devel zlib-devel \
    python3-pip \
    boost-devel cpprest-devel \
    grpc-devel grpc-plugins protobuf-devel protobuf-compiler
  do
    ${PKG} install -y "${pkg}" >/tmp/dnf-${pkg}.log 2>&1 \
      && log "  installed ${pkg}" \
      || log "  skip ${pkg} (not available or already present)"
  done

  # Prefer /usr/bin/python3 + pip for tooling (venv python often lacks pip)
  local PY=/usr/bin/python3
  [[ -x "${PY}" ]] || PY=python3
  if ! command -v meson >/dev/null 2>&1; then
    "${PY}" -m pip install --no-cache-dir 'meson>=0.64'
  fi
  if ! command -v ninja >/dev/null 2>&1; then
    "${PY}" -m pip install --no-cache-dir ninja
  fi
  # cmake: prefer RPM; fall back to pip cmake package
  if ! command -v cmake >/dev/null 2>&1; then
    "${PY}" -m pip install --no-cache-dir cmake
  fi
  command -v meson >/dev/null 2>&1 || die "meson not available after install"
  command -v ninja >/dev/null 2>&1 || die "ninja not available after install"
  command -v cmake >/dev/null 2>&1 || die "cmake not available after install"
  command -v git >/dev/null 2>&1 || die "git not available after install"
  command -v g++ >/dev/null 2>&1 || die "g++ not available after install"

  # UBI lacks protobuf C++ devel; pull Rocky 9 RPMs so etcd-cpp / grpc can build.
  install_rocky_protobuf_rpms
}

install_rocky_protobuf_rpms() {
  log "Installing protobuf/c-ares from Rocky Linux 9 RPMs (missing on UBI)..."
  local tmp=/tmp/rocky-build-rpms
  mkdir -p "${tmp}"
  local pb_ver=3.14.0-17.el9_7
  local ca_ver=1.19.1-2.el9_4
  local base_app_p=https://dl.rockylinux.org/pub/rocky/9/AppStream/x86_64/os/Packages/p
  local base_app_c=https://dl.rockylinux.org/pub/rocky/9/AppStream/x86_64/os/Packages/c
  local base_base_c=https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/c
  local base_crb_p=https://dl.rockylinux.org/pub/rocky/9/CRB/x86_64/os/Packages/p
  local rpm
  for rpm in \
    "${base_app_p}/protobuf-${pb_ver}.x86_64.rpm" \
    "${base_app_p}/protobuf-lite-${pb_ver}.x86_64.rpm" \
    "${base_crb_p}/protobuf-compiler-${pb_ver}.x86_64.rpm" \
    "${base_crb_p}/protobuf-devel-${pb_ver}.x86_64.rpm" \
    "${base_crb_p}/protobuf-lite-devel-${pb_ver}.x86_64.rpm" \
    "${base_base_c}/c-ares-${ca_ver}.x86_64.rpm" \
    "${base_app_c}/c-ares-devel-${ca_ver}.x86_64.rpm"
  do
    local bn
    bn="$(basename "${rpm}")"
    if [[ -f "${tmp}/${bn}" ]]; then
      continue
    fi
    log "  fetch ${bn}"
    curl -fsSL -o "${tmp}/${bn}" "${rpm}"
  done
  rpm -Uvh --nodeps "${tmp}"/*.rpm 2>/dev/null || dnf install -y "${tmp}"/*.rpm
  [[ -f /usr/include/google/protobuf/message.h ]] || die "protobuf headers still missing after Rocky RPM install"
  [[ -e /usr/lib64/libcares.so.2 || -e /usr/lib64/libcares.so ]] || die "c-ares still missing after Rocky RPM install"
  # grpc from EPEL should resolve now
  dnf install -y grpc grpc-devel grpc-plugins grpc-cpp 2>&1 | tail -20 \
    && log "  installed grpc packages" \
    || die "grpc RPMs still unavailable after protobuf/c-ares install"
}

install_build_deps

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# --- clone NIXL (headers + nixlbench sources); pin to image wheel version ---
log "Cloning NIXL ${NIXL_GIT_REF}..."
rm -rf nixl
git clone --depth 1 --branch "${NIXL_GIT_REF}" "${NIXL_REPO}" nixl
NIXL_SRC="${WORKDIR}/nixl"
NIXLBENCH_SRC="${NIXL_SRC}/benchmark/nixlbench"
[[ -d "${NIXLBENCH_SRC}" ]] || die "nixlbench sources missing at ${NIXLBENCH_SRC}"
[[ -f "${NIXL_SRC}/src/api/cpp/nixl.h" ]] || die "NIXL public headers missing in clone"

# --- stage link prefix: headers from source, libs from wheel ---
log "Staging link prefix at ${NIXL_LINK_PREFIX}"
rm -rf "${NIXL_LINK_PREFIX}"
mkdir -p "${NIXL_LINK_PREFIX}/include" "${NIXL_LINK_PREFIX}/lib64"

# Public API headers (installed as top-level includes)
cp -a "${NIXL_SRC}/src/api/cpp/"*.h "${NIXL_LINK_PREFIX}/include/"
# Nested API dirs if present (backend/, telemetry/, ...)
for sub in backend telemetry; do
  if [[ -d "${NIXL_SRC}/src/api/cpp/${sub}" ]]; then
    mkdir -p "${NIXL_LINK_PREFIX}/include/${sub}"
    cp -a "${NIXL_SRC}/src/api/cpp/${sub}/." "${NIXL_LINK_PREFIX}/include/${sub}/" 2>/dev/null || true
  fi
done
# Internal headers referenced as <utils/...>
mkdir -p "${NIXL_LINK_PREFIX}/include/utils"
cp -a "${NIXL_SRC}/src/utils/." "${NIXL_LINK_PREFIX}/include/utils/"

# Runtime libs + plugins from the wheel
ln -sfn "${NIXL_LIB_DIR}"/libnixl.so* "${NIXL_LINK_PREFIX}/lib64/" 2>/dev/null || true
ln -sfn "${NIXL_LIB_DIR}"/libnixl_build.so* "${NIXL_LINK_PREFIX}/lib64/" 2>/dev/null || true
ln -sfn "${NIXL_LIB_DIR}"/libserdes.so* "${NIXL_LINK_PREFIX}/lib64/" 2>/dev/null || true
ln -sfn "${NIXL_LIB_DIR}"/libnixl_common.so* "${NIXL_LINK_PREFIX}/lib64/" 2>/dev/null || true
if [[ -d "${NIXL_LIB_DIR}/plugins" ]]; then
  ln -sfn "${NIXL_LIB_DIR}/plugins" "${NIXL_LINK_PREFIX}/lib64/plugins"
fi
[[ -e "${NIXL_LINK_PREFIX}/lib64/libnixl.so" ]] || die "failed to stage libnixl into ${NIXL_LINK_PREFIX}/lib64"

# --- etcd-cpp-api (required for ETCD coordination) ---
if ! pkg-config --exists etcd-cpp-api 2>/dev/null \
  && [[ ! -f /usr/local/lib64/libetcd-cpp-api.so && ! -f /usr/local/lib/libetcd-cpp-api.so \
        && ! -f /usr/local/lib64/libetcd-cpp-api-core.so && ! -f /usr/local/lib/libetcd-cpp-api-core.so ]]; then
  log "Building etcd-cpp-apiv3..."
  rm -rf etcd-cpp-apiv3
  git clone --depth 1 "${ETCD_CPP_REPO}" etcd-cpp-apiv3
  if [[ -f etcd-cpp-apiv3/etcd-cpp-api-config.in.cmake ]]; then
    sed -i '/^find_dependency(cpprestsdk)$/d' etcd-cpp-apiv3/etcd-cpp-api-config.in.cmake || true
  fi
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y cpprest-devel grpc-devel grpc-plugins protobuf-devel protobuf-compiler 2>/dev/null || true
  fi
  cmake -S etcd-cpp-apiv3 -B etcd-cpp-apiv3/build \
    -DBUILD_ETCD_CORE_ONLY=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local
  cmake --build etcd-cpp-apiv3/build -j"$(nproc)"
  cmake --install etcd-cpp-apiv3/build
  ldconfig || true
else
  log "etcd-cpp-api already available"
fi

export PKG_CONFIG_PATH="/usr/local/lib64/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LIBRARY_PATH="/usr/local/lib64:/usr/local/lib:${NIXL_LINK_PREFIX}/lib64:${LIBRARY_PATH:-}"
export CPATH="${NIXL_LINK_PREFIX}/include:/usr/local/include:${CPATH:-}"
export LD_LIBRARY_PATH="/usr/local/lib64:/usr/local/lib:${LD_LIBRARY_PATH}"

ETCD_LIB_PATH=/usr/local/lib64
[[ -d /usr/local/lib64 ]] || ETCD_LIB_PATH=/usr/local/lib

# Skip NVSHMEM: its nvcc custom_target omits meson subproject includes.
# Link etcd against the wheel's libetcd (same grpc as libnixl) to avoid
# mixing /usr/local system grpc with the wheel grpc (causes SIGSEGV at init).
NIXL_EXTRA_LIB_DIR="${NIXL_EXTRA_LIB_DIR:-}"
if [[ -n "${NIXL_EXTRA_LIB_DIR}" ]] && compgen -G "${NIXL_EXTRA_LIB_DIR}/libetcd-cpp-api-core-*.so" >/dev/null 2>&1; then
  ln -sfn "${NIXL_EXTRA_LIB_DIR}"/libetcd-cpp-api-core-*.so "${NIXL_LINK_PREFIX}/lib64/libetcd-cpp-api-core.so"
  ETCD_LIB_PATH="${NIXL_LINK_PREFIX}/lib64"
  log "Using wheel etcd-cpp at ${ETCD_LIB_PATH}"
fi

log "Configuring nixlbench (nixl_path=${NIXL_LINK_PREFIX}, ref=${NIXL_GIT_REF})..."
rm -rf "${NIXLBENCH_SRC}/build"
meson setup "${NIXLBENCH_SRC}/build" "${NIXLBENCH_SRC}" \
  --prefix="${NIXLBENCH_PREFIX}" \
  --buildtype=release \
  -Dlibdir=lib64 \
  -Dnixl_path="${NIXL_LINK_PREFIX}" \
  -Dcudapath_inc=/usr/local/cuda/include \
  -Dcudapath_lib=/usr/local/cuda/lib64 \
  -Dcudapath_stub=/usr/local/cuda/lib64/stubs \
  -Detcd_inc_path=/usr/local/include \
  -Detcd_lib_path="${ETCD_LIB_PATH}"

# asio is a meson subproject; some nixlbench targets miss its include dir
ASIO_INC="${NIXLBENCH_SRC}/subprojects/asio-1.30.2/include"
if [[ ! -f "${ASIO_INC}/asio.hpp" ]]; then
  ASIO_INC="$(find "${NIXLBENCH_SRC}/subprojects" -path '*/asio-*/include/asio.hpp' -printf '%h\n' 2>/dev/null | head -1 || true)"
fi
[[ -n "${ASIO_INC}" && -f "${ASIO_INC}/asio.hpp" ]] || die "asio.hpp not found under nixlbench subprojects"
export CPATH="${ASIO_INC}:${NIXL_LINK_PREFIX}/include:/usr/local/cuda/include:${CPATH:-}"
export CXXFLAGS="-I${ASIO_INC} ${CXXFLAGS:-}"

log "Building nixlbench..."
ninja -C "${NIXLBENCH_SRC}/build"
ninja -C "${NIXLBENCH_SRC}/build" install

ln -sfn "${NIXLBENCH_PREFIX}/bin/nixlbench" /usr/local/bin/nixlbench

# LIBFABRIC plugin (nixl_cu12 wheel) needs libcudart.so.12; image may only ship CUDA 13.
if [[ ! -e /opt/nixl-for-bench/cuda12-lib/libcudart.so.12 ]]; then
  log "Installing nvidia-cuda-runtime-cu12 for LIBFABRIC plugin..."
  mkdir -p /opt/cuda12-compat
  pip3 install --no-cache-dir --target /opt/cuda12-compat "nvidia-cuda-runtime-cu12" >/dev/null
  CUDART="$(find /opt/cuda12-compat -name 'libcudart.so.12' | head -1)"
  [[ -n "${CUDART}" ]] || die "libcudart.so.12 not found after pip install"
  ln -sfn "$(dirname "${CUDART}")" /opt/nixl-for-bench/cuda12-lib
fi

# Persist env for later interactive/exec sessions.
# Omit /usr/local/lib64 so system etcd/grpc cannot clash with the wheel.
cat >/etc/profile.d/nixlbench.sh <<EOF
export PATH="${NIXLBENCH_PREFIX}/bin:/opt/amazon/efa/bin:/opt/ucx/bin:/usr/local/bin:\$PATH"
export LD_LIBRARY_PATH=/opt/nixl-for-bench/cuda12-lib:${NIXL_LIB_DIR}:${NIXL_EXTRA_LIB_DIR:-}:/opt/amazon/efa/lib64:/opt/amazon/efa/lib:/opt/ucx/lib64:/opt/ucx/lib:${NIXL_LINK_PREFIX}/lib64:/usr/lib64
export NIXL_PLUGIN_DIR="${NIXL_LIB_DIR}/plugins"
EOF

cat >/usr/local/nixlbench/env.sh <<EOF
export PATH="${NIXLBENCH_PREFIX}/bin:/opt/amazon/efa/bin:/opt/ucx/bin:/usr/local/bin:\$PATH"
export LD_LIBRARY_PATH=/opt/nixl-for-bench/cuda12-lib:${NIXL_LIB_DIR}:${NIXL_EXTRA_LIB_DIR:-}:/opt/amazon/efa/lib64:/opt/amazon/efa/lib:/opt/ucx/lib64:/opt/ucx/lib:${NIXL_LINK_PREFIX}/lib64:/usr/lib64
export NIXL_PLUGIN_DIR="${NIXL_LIB_DIR}/plugins"
export NIXL_LINK_PREFIX="${NIXL_LINK_PREFIX}"
export NIXLBENCH_PREFIX="${NIXLBENCH_PREFIX}"
EOF

date -u +"%Y-%m-%dT%H:%M:%SZ" >"${INSTALL_MARKER}"
echo "${NIXL_GIT_REF}" >"${NIXLBENCH_PREFIX}/.nixl-git-ref"

log "SUCCESS: nixlbench installed"
log "  binary:  ${NIXLBENCH_PREFIX}/bin/nixlbench"
log "  nixl ref:${NIXL_GIT_REF}"
log "  libs:    ${NIXL_LIB_DIR}"
log "  plugins: ${NIXL_LIB_DIR}/plugins"
"${NIXLBENCH_PREFIX}/bin/nixlbench" --help | head -40 || true
