#!/bin/bash
# Init container script: copies LIBFABRIC addon artifacts into shared volumes
# for the main vllm-cuda container to pick up.
#
# Expected volume mounts:
#   /target/plugins  — shared emptyDir, mounted into vLLM at NIXL_PLUGIN_DIR
#   /target/efa-libs  — shared emptyDir, mounted into vLLM at LD_LIBRARY_PATH

set -euo pipefail

PLUGINS_DIR="${1:-/target/plugins}"
EFA_LIBS_DIR="${2:-/target/efa-libs}"

echo "[libfabric-addon] Copying NIXL plugins (UCX + GDS + POSIX + LIBFABRIC)..."
cp -v /artifacts/plugins/*.so "${PLUGINS_DIR}/"

echo "[libfabric-addon] Copying EFA-enabled libfabric libraries..."
cp -av /artifacts/efa/lib/* "${EFA_LIBS_DIR}/"
cp -v /artifacts/efa/bin/fi_info "${EFA_LIBS_DIR}/" 2>/dev/null || true

echo "[libfabric-addon] Copying abseil shared libraries..."
cp -v /artifacts/abseil/lib/*.so* "${EFA_LIBS_DIR}/" 2>/dev/null || true

echo "[libfabric-addon] Done. Files injected:"
echo "  Plugins: $(ls "${PLUGINS_DIR}"/*.so 2>/dev/null | wc -l) .so files"
echo "  EFA libs: $(ls "${EFA_LIBS_DIR}"/lib* 2>/dev/null | wc -l) library files"
