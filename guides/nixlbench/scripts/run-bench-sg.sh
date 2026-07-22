#!/usr/bin/env bash
# Launch NUM_DEV nixlbench workers in SG mode inside one pod.
#
# SG = one process per GPU (matches vLLM TP=N: one NIXL agent per rank/GPU).
# World size is NUM_DEV initiators + NUM_DEV targets across two pods.
#
# Required:
#   BACKEND=LIBFABRIC|UCX|UCCL
#   ROLE=initiator|target   # this pod's side (start initiator pod first)
#
# Optional: same as run-bench.sh (NUM_DEV, ETCD_URL, BENCH_GROUP, OP_TYPE, ...)
#
# Example (two terminals, initiator first):
#   kubectl -n raj-nixlbench exec nixlbench-a -- \
#     env BACKEND=LIBFABRIC ROLE=initiator BENCH_GROUP=libfabric-sg \
#     bash /tmp/nixlbench-scripts/run-bench-sg.sh
#   kubectl -n raj-nixlbench exec nixlbench-b -- \
#     env BACKEND=LIBFABRIC ROLE=target BENCH_GROUP=libfabric-sg \
#     bash /tmp/nixlbench-scripts/run-bench-sg.sh
set -euo pipefail

NIXLBENCH_PREFIX="${NIXLBENCH_PREFIX:-/usr/local/nixlbench}"
NIXL_LINK_PREFIX="${NIXL_LINK_PREFIX:-/opt/nixl-for-bench}"

BACKEND="${BACKEND:?set BACKEND=LIBFABRIC, UCX, or UCCL}"

# shellcheck disable=SC1091
if [[ "${BACKEND}" == "UCCL" ]]; then
  [[ -f "${NIXLBENCH_PREFIX}/uccl-env.sh" ]] || {
    echo "[run-bench-sg] ERROR: ${NIXLBENCH_PREFIX}/uccl-env.sh missing; run install-uccl-p2p.sh first" >&2
    exit 1
  }
  source "${NIXLBENCH_PREFIX}/uccl-env.sh"
elif [[ -f /usr/local/nixlbench/env.sh ]]; then
  # shellcheck disable=SC1091
  source /usr/local/nixlbench/env.sh
fi

export PATH="${NIXLBENCH_PREFIX}/bin:/opt/amazon/efa/bin:/opt/ucx/bin:/usr/local/bin:/opt/vllm/bin:${PATH}"
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

ROLE="${ROLE:?set ROLE=initiator or target}"
ETCD_URL="${ETCD_URL:-http://etcd.raj-nixlbench.svc:2379}"
NUM_DEV="${NUM_DEV:-4}"
OP_TYPE="${OP_TYPE:-READ}"
INIT_SEG="${INIT_SEG:-VRAM}"
TARGET_SEG="${TARGET_SEG:-VRAM}"
BENCH_GROUP="${BENCH_GROUP:-sg-${BACKEND}}"
LOG_DIR="${LOG_DIR:-/tmp/nixlbench-sg-logs}"

case "${ROLE}" in
  initiator|target) ;;
  *)
    echo "[run-bench-sg] ERROR: ROLE must be initiator or target (got: ${ROLE})" >&2
    exit 1
    ;;
esac

case "${BACKEND}" in
  LIBFABRIC)
    export FI_PROVIDER="${FI_PROVIDER:-efa}"
    export FI_EFA_USE_DEVICE_RDMA="${FI_EFA_USE_DEVICE_RDMA:-1}"
    ;;
  UCX)
    export UCX_TLS="${UCX_TLS:-tcp,sm,self,cuda_copy,cuda_ipc}"
    export UCX_PROTO_INFO="${UCX_PROTO_INFO:-y}"
    export UCX_WARN_UNUSED_ENV_VARS="${UCX_WARN_UNUSED_ENV_VARS:-n}"
    ;;
  UCCL)
    export UCCL_P2P_TRANSPORT="${UCCL_P2P_TRANSPORT:-efa}"
    export UCCL_P2P_LOG_LEVEL="${UCCL_P2P_LOG_LEVEL:-INFO}"
    # UC only supports WRITE; READ needs reliable connection mode.
    export UCCL_RCMODE="${UCCL_RCMODE:-1}"
    [[ -e "${NIXL_PLUGIN_DIR}/libplugin_UCCL.so" ]] || {
      echo "[run-bench-sg] ERROR: libplugin_UCCL.so not in NIXL_PLUGIN_DIR=${NIXL_PLUGIN_DIR}" >&2
      exit 1
    }
    ;;
  *)
    echo "[run-bench-sg] ERROR: BACKEND must be LIBFABRIC, UCX, or UCCL (got: ${BACKEND})" >&2
    exit 1
    ;;
esac

command -v nixlbench >/dev/null 2>&1 || {
  echo "[run-bench-sg] ERROR: nixlbench not found; run install-nixlbench.sh first" >&2
  exit 1
}

HOST="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"
mkdir -p "${LOG_DIR}"
rm -f "${LOG_DIR}"/rank-*.log "${LOG_DIR}"/worker-*.pid 2>/dev/null || true

# GPU selection in SG: nixlbench uses cudaSetDevice(rank) for initiators and
# cudaSetDevice(rank-num_initiator) for targets. Keep --device_list=all (default).
# Do NOT pass a numeric device_list with LIBFABRIC: the LIBFABRIC path indexes
# devices[rank] (not devices[local_rank]) and aborts on targets (OOB).
# Do NOT use CUDA_VISIBLE_DEVICES: cudaSetDevice(rank) then fails with ordinal errors.

echo "[run-bench-sg] backend=${BACKEND} role=${ROLE} host=${HOST}"
echo "[run-bench-sg] etcd=${ETCD_URL} group=${BENCH_GROUP}"
echo "[run-bench-sg] mode=SG workers=${NUM_DEV} (world=$((NUM_DEV * 2))) op=${OP_TYPE}"
echo "[run-bench-sg] device_list=all; GPU = etcd local rank (vLLM TP-like, 1 agent/GPU)"
if [[ "${BACKEND}" == "UCCL" ]]; then
  echo "[run-bench-sg] UCCL_P2P_TRANSPORT=${UCCL_P2P_TRANSPORT} NIXL_PLUGIN_DIR=${NIXL_PLUGIN_DIR}"
fi
echo "[run-bench-sg] start peer pod within ~60s; initiator pod should register first"

PIDS=()
for i in $(seq 0 $((NUM_DEV - 1))); do
  log="${LOG_DIR}/rank-${ROLE}-${i}.log"
  # Identical argv on every worker; etcd rank selects initiator vs target and GPU.
  # shellcheck disable=SC2086
  nixlbench \
    --etcd_endpoints "${ETCD_URL}" \
    --benchmark_group "${BENCH_GROUP}" \
    --backend "${BACKEND}" \
    --mode SG \
    --initiator_seg_type "${INIT_SEG}" \
    --target_seg_type "${TARGET_SEG}" \
    --op_type "${OP_TYPE}" \
    --num_initiator_dev "${NUM_DEV}" \
    --num_target_dev "${NUM_DEV}" \
    --check_consistency \
    ${EXTRA_ARGS:-} \
    >"${log}" 2>&1 &
  pid=$!
  PIDS+=("${pid}")
  echo "${pid}" >"${LOG_DIR}/worker-${ROLE}-${i}.pid"
  echo "[run-bench-sg] started ${ROLE} worker=${i} pid=${pid} log=${log}"
  # Stagger slightly so etcd rank assignment is stable within a pod.
  sleep 0.5
done
ec=0
for pid in "${PIDS[@]}"; do
  if ! wait "${pid}"; then
    ec=1
  fi
done

echo "[run-bench-sg] all ${NUM_DEV} ${ROLE} workers finished (exit aggregate=${ec})"
# Rank 0 (initiator gpu0) prints the BW table — surface it when present.
if [[ "${ROLE}" == "initiator" && -f "${LOG_DIR}/rank-initiator-0.log" ]]; then
  echo "[run-bench-sg] === initiator rank0 results (tail) ==="
  grep -E '^[0-9]|Block Size|B/W|Mode |Backend|Num initiator|failed|ERROR' \
    "${LOG_DIR}/rank-initiator-0.log" | tail -40 || true
fi
exit "${ec}"
