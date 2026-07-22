#!/usr/bin/env bash
# Install UCCL P2P v0.1.1 + NIXL libplugin_UCCL.so inside an llm-d-aws pod.
#
# Does NOT rebuild/replace the image NIXL wheel. Order:
#   1) build/install libuccl_p2p (native make; EFA via dlopen + runtime UCCL_P2P_TRANSPORT=efa)
#   2) clone NIXL v1.2.0 source; meson -Denable_plugins=UCCL; copy only libplugin_UCCL.so
#   3) stage merged NIXL_PLUGIN_DIR (wheel plugins + UCCL) and write uccl-env.sh
#
# Prefer nixl_cu13 (matches image CUDA 13 / P/D default).
set -euo pipefail

UCCL_GIT_REF="${UCCL_GIT_REF:-v0.1.1}"
UCCL_REPO="${UCCL_REPO:-https://github.com/uccl-project/uccl.git}"
NIXL_GIT_REF="${NIXL_GIT_REF:-v1.2.0}"
NIXL_REPO="${NIXL_REPO:-https://github.com/ai-dynamo/nixl.git}"
WORKDIR="${WORKDIR:-/tmp/uccl-p2p-build}"
PREFIX="${PREFIX:-/opt/uccl-p2p}"
EFA_HOME="${EFA_HOME:-/opt/amazon/efa}"
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
NIXLBENCH_PREFIX="${NIXLBENCH_PREFIX:-/usr/local/nixlbench}"
INSTALL_MARKER="${INSTALL_MARKER:-${PREFIX}/.install-complete}"

log() { echo "[install-uccl-p2p] $*"; }
die() { echo "[install-uccl-p2p] ERROR: $*" >&2; exit 1; }

export PATH="/opt/amazon/efa/bin:/opt/ucx/bin:/usr/local/bin:/opt/vllm/bin:${PATH}"
export EFA_HOME CUDA_HOME

if [[ -f "${INSTALL_MARKER}" && -e "${PREFIX}/nixl-plugins/libplugin_UCCL.so" && -e "${PREFIX}/lib/libuccl_p2p.so" ]]; then
  log "UCCL P2P already installed at ${PREFIX} (marker present); skipping"
  log "Source ${NIXLBENCH_PREFIX}/uccl-env.sh before UCCL benches"
  exit 0
fi

[[ -d "${EFA_HOME}" ]] || die "${EFA_HOME} missing (need EFA libs/headers on llm-d-aws)"
[[ -d "${CUDA_HOME}/include" ]] || die "${CUDA_HOME} missing"

# --- prefer nixl_cu13 (CUDA 13 image / P/D default) ---
discover_nixl_lib_dir() {
  local d
  for d in \
    /opt/vllm/lib/python3.12/site-packages/.nixl_cu13.mesonpy.libs \
    /opt/vllm/lib64/python3.12/site-packages/.nixl_cu13.mesonpy.libs \
    /opt/vllm/lib/python3.12/site-packages/.nixl_cu12.mesonpy.libs \
    /opt/vllm/lib64/python3.12/site-packages/.nixl_cu12.mesonpy.libs
  do
    if [[ -e "${d}/libnixl.so" && -d "${d}/plugins" ]]; then
      echo "${d}"
      return 0
    fi
  done
  return 1
}

discover_nixl_extra_lib_dir() {
  local d
  for d in \
    /opt/vllm/lib/python3.12/site-packages/nixl_cu13.libs \
    /opt/vllm/lib64/python3.12/site-packages/nixl_cu13.libs \
    /opt/vllm/lib/python3.12/site-packages/nixl_cu12.libs \
    /opt/vllm/lib64/python3.12/site-packages/nixl_cu12.libs
  do
    if [[ -d "${d}" ]]; then
      echo "${d}"
      return 0
    fi
  done
  return 1
}

NIXL_LIB_DIR="$(discover_nixl_lib_dir)" || die "libnixl.so + plugins not found under /opt/vllm (nixl_cu13/cu12)"
NIXL_EXTRA_LIB_DIR="$(discover_nixl_extra_lib_dir || true)"
WHEEL_PLUGIN_DIR="${NIXL_LIB_DIR}/plugins"
[[ -d "${WHEEL_PLUGIN_DIR}" ]] || die "wheel plugins missing at ${WHEEL_PLUGIN_DIR}"
log "NIXL wheel libs: ${NIXL_LIB_DIR}"
log "NIXL extra libs: ${NIXL_EXTRA_LIB_DIR:-<none>}"

# --- build deps ---
install_build_deps() {
  local PKG
  if command -v dnf >/dev/null 2>&1; then
    PKG=dnf
  elif command -v microdnf >/dev/null 2>&1; then
    PKG=microdnf
  elif command -v yum >/dev/null 2>&1; then
    PKG=yum
  else
    die "no dnf/yum found"
  fi

  log "Installing build dependencies via ${PKG}..."
  local pkg
  for pkg in \
    git gcc-c++ make cmake ninja-build pkgconfig \
    openssl-devel zlib-devel elfutils-libelf-devel \
    python3-pip python3-devel \
    libgomp
  do
    ${PKG} install -y "${pkg}" >/tmp/dnf-uccl-${pkg}.log 2>&1 \
      && log "  installed ${pkg}" \
      || log "  skip ${pkg}"
  done

  # Prefer system python3 for meson/ninja — /usr/local/bin/meson may be a stale
  # wrapper whose shebang python lacks mesonbuild (seen on llm-d-aws pods).
  PY=/usr/bin/python3
  [[ -x "${PY}" ]] || PY="$(command -v python3)"
  log "Ensuring meson/ninja via ${PY}..."
  "${PY}" -m pip install --no-cache-dir --upgrade 'meson>=0.64' ninja >/tmp/pip-meson.log 2>&1 \
    || die "pip install meson/ninja failed (see /tmp/pip-meson.log)"
  "${PY}" -m pip install --no-cache-dir 'nanobind>=2.0' pybind11 >/tmp/pip-nanobind.log 2>&1 \
    || die "failed to pip install nanobind"
  "${PY}" -c "import mesonbuild" || die "mesonbuild not importable by ${PY}"
  command -v g++ >/dev/null 2>&1 || die "g++ not available"
  command -v git >/dev/null 2>&1 || die "git not available"
  # Prefer python -m over broken /usr/local/bin/meson
  MESON_CMD=("${PY}" -m mesonbuild.mesonmain)
  NINJA_CMD=(ninja)
  if ! command -v ninja >/dev/null 2>&1; then
    NINJA_CMD=("${PY}" -m ninja)
  fi
  export MESON_CMD NINJA_CMD PY
}

install_build_deps
# Re-bind arrays after function (bash export of arrays is unreliable)
PY="${PY:-/usr/bin/python3}"
MESON_CMD=("${PY}" -m mesonbuild.mesonmain)
if command -v ninja >/dev/null 2>&1; then
  NINJA_CMD=(ninja)
else
  NINJA_CMD=("${PY}" -m ninja)
fi
log "Using meson: ${MESON_CMD[*]}"
log "Using ninja: ${NINJA_CMD[*]}"

mkdir -p "${WORKDIR}" "${PREFIX}/lib" "${PREFIX}/include" "${PREFIX}/nixl-plugins"
cd "${WORKDIR}"

# =============================================================================
# 1) UCCL P2P (native make — build.sh requires Docker, not used here)
# =============================================================================
if [[ -e "${PREFIX}/lib/libuccl_p2p.so" && -f "${PREFIX}/include/uccl_engine.h" && -f "${PREFIX}/include/common.h" ]]; then
  log "Reusing existing libuccl_p2p at ${PREFIX}/lib (skip rebuild)"
else
  log "Cloning UCCL ${UCCL_GIT_REF}..."
  rm -rf uccl
  git clone --depth 1 --branch "${UCCL_GIT_REF}" "${UCCL_REPO}" uccl
  UCCL_SRC="${WORKDIR}/uccl"
  [[ -f "${UCCL_SRC}/p2p/Makefile" ]] || die "p2p/Makefile missing in UCCL ${UCCL_GIT_REF}"

  log "Building libuccl_p2p (EFA_HOME=${EFA_HOME})..."
  cd "${UCCL_SRC}/p2p"
  # v0.1.1: single binary; EFA via dlopen(libefa). Transport selected at runtime.
  make clean >/dev/null 2>&1 || true
  make -j"$(nproc)" libuccl_p2p.so \
    EFA_HOME="${EFA_HOME}" \
    CUDA_HOME="${CUDA_HOME}" \
    PREFIX="${PREFIX}"

  [[ -f libuccl_p2p.so ]] || die "libuccl_p2p.so not produced"
  install -m 755 libuccl_p2p.so "${PREFIX}/lib/"
  install -m 644 uccl_engine.h "${PREFIX}/include/"
  if [[ -d include ]]; then
    cp -a include/. "${PREFIX}/include/" 2>/dev/null || true
  fi
  [[ -f common.h ]] && install -m 644 common.h "${PREFIX}/include/" || true
  [[ -f "${PREFIX}/include/common.h" ]] || die "common.h not found after UCCL p2p install"
  log "libuccl_p2p installed under ${PREFIX}/lib"
fi

# =============================================================================
# 2) NIXL source — build ONLY libplugin_UCCL.so (do not install full NIXL)
# =============================================================================
cd "${WORKDIR}"
log "Cloning NIXL ${NIXL_GIT_REF} (plugin sources only; will not replace wheel)..."
rm -rf nixl
git clone --depth 1 --branch "${NIXL_GIT_REF}" "${NIXL_REPO}" nixl
NIXL_SRC="${WORKDIR}/nixl"
[[ -f "${NIXL_SRC}/src/plugins/uccl/uccl_plugin.cpp" ]] || die "UCCL plugin sources missing in NIXL ${NIXL_GIT_REF}"

# nixlbench is a C++ agent (not Python). Upstream defaults in_python=1 which
# calls PyGIL* and segfaults outside a Python process — force default 0.
if grep -q 'getNixlParam(custom_params, "in_python", 1)' \
  "${NIXL_SRC}/src/plugins/uccl/uccl_backend.cpp"; then
  log "Patching UCCL backend default in_python=0 for nixlbench..."
  sed -i 's/getNixlParam(custom_params, "in_python", 1)/getNixlParam(custom_params, "in_python", 0)/' \
    "${NIXL_SRC}/src/plugins/uccl/uccl_backend.cpp"
fi

export LIBRARY_PATH="${PREFIX}/lib:${NIXL_LIB_DIR}:${NIXL_EXTRA_LIB_DIR:-}:${CUDA_HOME}/lib64:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="${PREFIX}/lib:${NIXL_LIB_DIR}:${NIXL_EXTRA_LIB_DIR:-}:${EFA_HOME}/lib64:${EFA_HOME}/lib:${CUDA_HOME}/lib64:${LD_LIBRARY_PATH:-}"
export CPATH="${PREFIX}/include:${CUDA_HOME}/include:${CPATH:-}"
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# NIXL 1.2.0 needs Abseil with absl_log. UBI/RHEL often ship 20211102 without it;
# meson then refuses the wrap fallback. Hide old absl_*.pc so wrap is used.
if pkg-config --exists absl_base 2>/dev/null && ! pkg-config --exists absl_log 2>/dev/null; then
  log "Hiding stale system Abseil pkg-config (no absl_log) so meson uses wrap..."
  mkdir -p /tmp/absl-pc-bak
  shopt -s nullglob
  for pc in /usr/lib64/pkgconfig/absl_*.pc /usr/lib/pkgconfig/absl_*.pc \
            /usr/share/pkgconfig/absl_*.pc; do
    mv -f "${pc}" /tmp/absl-pc-bak/ 2>/dev/null || true
  done
  shopt -u nullglob
fi

log "Configuring NIXL meson with -Denable_plugins=UCCL (tests/examples off)..."
rm -rf "${NIXL_SRC}/build"
# Point compiler at installed libuccl_p2p; meson find_library searches LIBRARY_PATH / system dirs.
"${MESON_CMD[@]}" setup "${NIXL_SRC}/build" "${NIXL_SRC}" \
  --prefix=/tmp/nixl-uccl-discard \
  --buildtype=release \
  -Dlibdir=lib64 \
  -Denable_plugins=UCCL \
  -Dbuild_tests=false \
  -Dbuild_examples=false \
  -Ddisable_gds_backend=true \
  -Ddisable_mooncake_backend=true \
  -Dcudapath_inc="${CUDA_HOME}/include" \
  -Dcudapath_lib="${CUDA_HOME}/lib64" \
  -Dcudapath_stub="${CUDA_HOME}/lib64/stubs" \
  -Dinstall_headers=false

# Confirm UCCL plugin is in the build graph
if ! "${NINJA_CMD[@]}" -C "${NIXL_SRC}/build" -t targets all 2>/dev/null | grep -qi 'plugin_UCCL\|libplugin_UCCL'; then
  log "Listing plugin-related ninja targets..."
  "${NINJA_CMD[@]}" -C "${NIXL_SRC}/build" -t targets all 2>/dev/null | grep -iE 'uccl|plugin' || true
fi

log "Building UCCL plugin (and its meson deps; wheel remains the runtime NIXL)..."
# Build everything meson needs for the plugin; we only keep libplugin_UCCL.so
set +e
"${NINJA_CMD[@]}" -C "${NIXL_SRC}/build" src/plugins/uccl/libplugin_UCCL.so
ninja_ec=$?
set -e
PLUGIN_BUILT="$(find "${NIXL_SRC}/build" -name 'libplugin_UCCL.so' 2>/dev/null | head -1 || true)"
if [[ -z "${PLUGIN_BUILT}" ]]; then
  # Fallback: build default then search
  [[ "${ninja_ec}" -eq 0 ]] || "${NINJA_CMD[@]}" -C "${NIXL_SRC}/build"
  PLUGIN_BUILT="$(find "${NIXL_SRC}/build" -name 'libplugin_UCCL.so' 2>/dev/null | head -1 || true)"
fi
[[ -n "${PLUGIN_BUILT}" ]] || die "libplugin_UCCL.so not found after meson/ninja (is libuccl_p2p discoverable?)"

install -m 755 "${PLUGIN_BUILT}" "${PREFIX}/nixl-plugins/libplugin_UCCL.so"
log "Staged plugin: ${PREFIX}/nixl-plugins/libplugin_UCCL.so"
ldd "${PREFIX}/nixl-plugins/libplugin_UCCL.so" || true

# =============================================================================
# 3) Merged plugin dir (NIXL_PLUGIN_DIR is typically exclusive)
# =============================================================================
log "Merging wheel plugins + UCCL into ${PREFIX}/nixl-plugins..."
for f in "${WHEEL_PLUGIN_DIR}"/*.so; do
  [[ -e "${f}" ]] || continue
  base="$(basename "${f}")"
  # Keep our freshly built UCCL; symlink the rest from the wheel
  if [[ "${base}" == "libplugin_UCCL.so" ]]; then
    continue
  fi
  ln -sfn "${f}" "${PREFIX}/nixl-plugins/${base}"
done

# =============================================================================
# 4) Runtime env
# =============================================================================
mkdir -p "${NIXLBENCH_PREFIX}"
cat >"${NIXLBENCH_PREFIX}/uccl-env.sh" <<EOF
# Generated by install-uccl-p2p.sh — source before BACKEND=UCCL runs
# Do not append inherited LD_LIBRARY_PATH (image stubs can break nixlbench/grpc).
export PATH="${NIXLBENCH_PREFIX}/bin:/opt/amazon/efa/bin:/opt/ucx/bin:/usr/local/bin:/opt/vllm/bin:\$PATH"
export LD_LIBRARY_PATH="${PREFIX}/lib:${NIXL_LIB_DIR}:${NIXL_EXTRA_LIB_DIR:-}:${EFA_HOME}/lib64:${EFA_HOME}/lib:/opt/ucx/lib64:/opt/ucx/lib:/opt/nixl-for-bench/lib64:${CUDA_HOME}/lib64:/usr/lib64"
export NIXL_PLUGIN_DIR="${PREFIX}/nixl-plugins"
export UCCL_P2P_TRANSPORT="\${UCCL_P2P_TRANSPORT:-efa}"
export UCCL_P2P_LOG_LEVEL="\${UCCL_P2P_LOG_LEVEL:-INFO}"
# UC only supports WRITE; READ needs RC mode.
export UCCL_RCMODE="\${UCCL_RCMODE:-1}"
export EFA_HOME="${EFA_HOME}"
# Leave UCCL_P2P_RDMA_DEV unset for PCIe-affinity auto NIC pick; set to override.
EOF

# Also append a hint into profile.d (does not override nixlbench env.sh NIXL_PLUGIN_DIR)
cat >/etc/profile.d/uccl-p2p.sh <<EOF
# UCCL P2P: source ${NIXLBENCH_PREFIX}/uccl-env.sh for BACKEND=UCCL
EOF

date -u +"%Y-%m-%dT%H:%M:%SZ" >"${INSTALL_MARKER}"
echo "${UCCL_GIT_REF}" >"${PREFIX}/.uccl-git-ref"
echo "${NIXL_GIT_REF}" >"${PREFIX}/.nixl-git-ref"

log "SUCCESS: UCCL P2P + NIXL UCCL plugin installed"
log "  libuccl_p2p: ${PREFIX}/lib/libuccl_p2p.so"
log "  plugin:      ${PREFIX}/nixl-plugins/libplugin_UCCL.so"
log "  env:         ${NIXLBENCH_PREFIX}/uccl-env.sh"
log "  transport:   UCCL_P2P_TRANSPORT=efa (set in uccl-env.sh)"
log "Run: CHECK_UCCL=1 bash check-nixlbench.sh"
