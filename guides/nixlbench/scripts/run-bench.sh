#!/usr/bin/env bash
# Run one nixlbench experiment inside a pod.
#
# Required:
#   BACKEND=LIBFABRIC|UCX|UCCL
#
# Optional env:
#   ETCD_URL          default http://etcd.raj-nixlbench.svc:2379
#   NUM_DEV           default 4  (num_initiator_dev / num_target_dev)
#   MODE              default MG (one process, multi-GPU).
#                     For SG (one process per GPU, vLLM TP-like) use run-bench-sg.sh.
#   OP_TYPE           default READ
#   NIXL_LOG_LEVEL    default INFO
#   UCX_TLS           default tcp,sm,self,cuda_copy,cuda_ipc (UCX only).
#                     NOTE: llm-d-aws v0.8.1 NIXL wheel embeds a UCX without EFA/IB;
#                     For EFA RDMA use BACKEND=LIBFABRIC or BACKEND=UCCL.
#   UCX_PROTO_INFO    default y                                      (UCX only)
#   UCCL_P2P_TRANSPORT default efa                                   (UCCL only)
#   EXTRA_ARGS        extra args appended to nixlbench
set -euo pipefail

NIXLBENCH_PREFIX="${NIXLBENCH_PREFIX:-/usr/local/nixlbench}"
NIXL_LINK_PREFIX="${NIXL_LINK_PREFIX:-/opt/nixl-for-bench}"

BACKEND="${BACKEND:?set BACKEND=LIBFABRIC, UCX, or UCCL}"

# UCCL needs its merged plugin dir + libuccl_p2p (overrides wheel-only env.sh).
# shellcheck disable=SC1091
if [[ "${BACKEND}" == "UCCL" ]]; then
  [[ -f "${NIXLBENCH_PREFIX}/uccl-env.sh" ]] || {
    echo "[run-bench] ERROR: ${NIXLBENCH_PREFIX}/uccl-env.sh missing; run install-uccl-p2p.sh first" >&2
    exit 1
  }
  source "${NIXLBENCH_PREFIX}/uccl-env.sh"
elif [[ -f /usr/local/nixlbench/env.sh ]]; then
  # shellcheck disable=SC1091
  source /usr/local/nixlbench/env.sh
fi

export PATH="${NIXLBENCH_PREFIX}/bin:/opt/amazon/efa/bin:/opt/ucx/bin:/usr/local/bin:/opt/vllm/bin:${PATH}"
# Prefer env.sh; if absent, assemble a safe path (no /usr/local/lib64 — grpc clash).
if [[ -z "${NIXL_PLUGIN_DIR:-}" ]]; then
  for d in \
    /opt/vllm/lib/python3.12/site-packages/.nixl_cu12.mesonpy.libs \
    /opt/vllm/lib64/python3.12/site-packages/.nixl_cu12.mesonpy.libs
  do
    if [[ -d "${d}" ]]; then
      export LD_LIBRARY_PATH="${d}:${LD_LIBRARY_PATH:-}"
      export NIXL_PLUGIN_DIR="${d}/plugins"
      break
    fi
  done
  for d in \
    /opt/vllm/lib/python3.12/site-packages/nixl_cu12.libs \
    /opt/vllm/lib64/python3.12/site-packages/nixl_cu12.libs
  do
    [[ -d "${d}" ]] && export LD_LIBRARY_PATH="${d}:${LD_LIBRARY_PATH:-}" && break
  done
  export LD_LIBRARY_PATH="/opt/nixl-for-bench/cuda12-lib:/opt/amazon/efa/lib64:/opt/amazon/efa/lib:/opt/ucx/lib64:/opt/ucx/lib:${NIXL_LINK_PREFIX}/lib64:/usr/lib64:${LD_LIBRARY_PATH:-}"
fi
export NIXL_LOG_LEVEL="${NIXL_LOG_LEVEL:-INFO}"

ETCD_URL="${ETCD_URL:-http://etcd.raj-nixlbench.svc:2379}"
NUM_DEV="${NUM_DEV:-4}"
MODE="${MODE:-MG}"
OP_TYPE="${OP_TYPE:-READ}"
INIT_SEG="${INIT_SEG:-VRAM}"
TARGET_SEG="${TARGET_SEG:-VRAM}"
BENCH_GROUP="${BENCH_GROUP:-default}"

case "${BACKEND}" in
  LIBFABRIC)
    export FI_PROVIDER="${FI_PROVIDER:-efa}"
    export FI_EFA_USE_DEVICE_RDMA="${FI_EFA_USE_DEVICE_RDMA:-1}"
    echo "[run-bench] backend=LIBFABRIC FI_PROVIDER=${FI_PROVIDER}"
    ;;
  UCX)
    # Wheel-bundled UCX has no efa/srd; use TCP (+ CUDA IPC). Prefer LIBFABRIC/UCCL for EFA.
    export UCX_TLS="${UCX_TLS:-tcp,sm,self,cuda_copy,cuda_ipc}"
    export UCX_PROTO_INFO="${UCX_PROTO_INFO:-y}"
    export UCX_WARN_UNUSED_ENV_VARS="${UCX_WARN_UNUSED_ENV_VARS:-n}"
    echo "[run-bench] backend=UCX UCX_TLS=${UCX_TLS} UCX_PROTO_INFO=${UCX_PROTO_INFO}"
    ;;
  UCCL)
    export UCCL_P2P_TRANSPORT="${UCCL_P2P_TRANSPORT:-efa}"
    export UCCL_P2P_LOG_LEVEL="${UCCL_P2P_LOG_LEVEL:-INFO}"
    # UC only supports WRITE; READ needs reliable connection mode.
    export UCCL_RCMODE="${UCCL_RCMODE:-1}"
    [[ -e "${NIXL_PLUGIN_DIR}/libplugin_UCCL.so" ]] || {
      echo "[run-bench] ERROR: libplugin_UCCL.so not in NIXL_PLUGIN_DIR=${NIXL_PLUGIN_DIR}" >&2
      exit 1
    }
    echo "[run-bench] backend=UCCL UCCL_P2P_TRANSPORT=${UCCL_P2P_TRANSPORT} UCCL_RCMODE=${UCCL_RCMODE} NIXL_PLUGIN_DIR=${NIXL_PLUGIN_DIR}"
    ;;
  *)
    echo "[run-bench] ERROR: BACKEND must be LIBFABRIC, UCX, or UCCL (got: ${BACKEND})" >&2
    exit 1
    ;;
esac

command -v nixlbench >/dev/null 2>&1 || {
  echo "[run-bench] ERROR: nixlbench not found; run install-nixlbench.sh first" >&2
  exit 1
}

HOST="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"
echo "[run-bench] etcd=${ETCD_URL} group=${BENCH_GROUP}"
echo "[run-bench] host=${HOST} mode=${MODE} gpus=${NUM_DEV} op=${OP_TYPE} segs=${INIT_SEG}/${TARGET_SEG}"
echo "[run-bench] starting nixlbench (start peer within ~60s)..."

# shellcheck disable=SC2086
exec nixlbench \
  --etcd_endpoints "${ETCD_URL}" \
  --benchmark_group "${BENCH_GROUP}" \
  --backend "${BACKEND}" \
  --mode "${MODE}" \
  --initiator_seg_type "${INIT_SEG}" \
  --target_seg_type "${TARGET_SEG}" \
  --op_type "${OP_TYPE}" \
  --num_initiator_dev "${NUM_DEV}" \
  --num_target_dev "${NUM_DEV}" \
  --check_consistency \
  ${EXTRA_ARGS:-}
