#!/usr/bin/env bash
# Host-side orchestrator: UCCL SG (default) then optional MG on raj-nixlbench pods.
# UCCL is one engine per NIXL agent (local_gpu_idx on first register) — SG matches
# vLLM TP and UCCL's own multi-GPU benches. MG is often a poor fit; set RUN_MG=1 to try.
# Run under nohup so Cursor disconnect does not stop the suite.
set -euo pipefail

NS="${NS:-raj-nixlbench}"
RESULTS="${RESULTS:-/tmp/nixlbench-results}"
NUM_DEV="${NUM_DEV:-4}"
RUN_SG="${RUN_SG:-1}"
RUN_MG="${RUN_MG:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "${RESULTS}"
log() { echo "[uccl-suite $(date -u +%H:%M:%SZ)] $*"; }

copy_scripts() {
  local p s
  for p in nixlbench-a nixlbench-b; do
    kubectl -n "${NS}" exec "$p" -- mkdir -p /tmp/nixlbench-scripts
    for s in run-bench.sh run-bench-sg.sh; do
      kubectl -n "${NS}" cp "${SCRIPT_DIR}/${s}" "${p}:/tmp/nixlbench-scripts/${s}"
    done
    kubectl -n "${NS}" exec "$p" -- chmod +x \
      /tmp/nixlbench-scripts/run-bench.sh \
      /tmp/nixlbench-scripts/run-bench-sg.sh
  done
}

clear_etcd() {
  kubectl -n "${NS}" exec deploy/etcd -- \
    etcdctl --endpoints=http://127.0.0.1:2379 del --prefix xferbench >/dev/null 2>&1 || true
}

# Write a tiny launcher in the pod and nohup it.
start_mg() {
  local pod="$1"
  kubectl -n "${NS}" exec "${pod}" -- bash -lc "
    cat > /tmp/launch-uccl-mg.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
export BACKEND=UCCL MODE=MG NUM_DEV=${NUM_DEV} BENCH_GROUP=uccl-mg
exec bash /tmp/nixlbench-scripts/run-bench.sh
EOS
    # expand NUM_DEV into the file
    sed -i 's/\${NUM_DEV}/${NUM_DEV}/g' /tmp/launch-uccl-mg.sh
    chmod +x /tmp/launch-uccl-mg.sh
    : > /tmp/uccl-mg.log
    nohup /tmp/launch-uccl-mg.sh >>/tmp/uccl-mg.log 2>&1 </dev/null &
    echo \$! > /tmp/uccl-mg.pid
    sleep 1
    kill -0 \"\$(cat /tmp/uccl-mg.pid)\" 
    echo started \$(cat /tmp/uccl-mg.pid)
  "
}

start_sg() {
  local pod="$1" role="$2"
  kubectl -n "${NS}" exec "${pod}" -- bash -lc "
    cat > /tmp/launch-uccl-sg.sh <<EOS
#!/usr/bin/env bash
set -euo pipefail
export BACKEND=UCCL ROLE=${role} NUM_DEV=${NUM_DEV} BENCH_GROUP=uccl-sg
exec bash /tmp/nixlbench-scripts/run-bench-sg.sh
EOS
    chmod +x /tmp/launch-uccl-sg.sh
    : > /tmp/uccl-sg.log
    nohup /tmp/launch-uccl-sg.sh >>/tmp/uccl-sg.log 2>&1 </dev/null &
    echo \$! > /tmp/uccl-sg.pid
    sleep 1
    kill -0 \"\$(cat /tmp/uccl-sg.pid)\"
    echo started \$(cat /tmp/uccl-sg.pid) role=${role}
  "
}

wait_job() {
  local pod="$1" name="$2" timeout_s="${3:-3600}"
  local i=0 alive
  while (( i < timeout_s )); do
    alive="$(kubectl -n "${NS}" exec "${pod}" -- bash -lc "
      pid=\$(cat /tmp/${name}.pid 2>/dev/null || true)
      [[ -n \"\$pid\" ]] || { echo dead; exit 0; }
      stat=\$(ps -p \"\$pid\" -o stat= 2>/dev/null || echo gone)
      if [[ \"\$stat\" == *Z* || \"\$stat\" == gone ]]; then echo dead; else echo alive; fi
    " 2>/dev/null | tail -1)"
    if [[ "${alive}" == "dead" ]]; then
      log "${pod}/${name} finished"
      return 0
    fi
    if (( i % 60 == 0 )); then
      log "waiting ${pod}/${name} t=${i}s"
      kubectl -n "${NS}" exec "${pod}" -- tail -5 "/tmp/${name}.log" 2>/dev/null | sed 's/^/  /' || true
    fi
    sleep 10
    i=$((i + 10))
  done
  log "TIMEOUT ${pod}/${name}"
  return 1
}

log "=== UCCL suite start RUN_SG=${RUN_SG} RUN_MG=${RUN_MG} NUM_DEV=${NUM_DEV} ==="
copy_scripts

if [[ "${RUN_SG}" == "1" ]]; then
  log "UCCL SG"
  clear_etcd
  kubectl -n "${NS}" exec nixlbench-a -- bash -lc 'killall -9 nixlbench 2>/dev/null || true' || true
  kubectl -n "${NS}" exec nixlbench-b -- bash -lc 'killall -9 nixlbench 2>/dev/null || true' || true
  sleep 2
  start_sg nixlbench-a initiator
  for i in $(seq 1 40); do
    n="$(kubectl -n "${NS}" exec nixlbench-a -- bash -lc \
      'ps -eo stat,cmd | grep "[n]ixlbench --" | grep -vc defunct' 2>/dev/null | tr -d ' ' || echo 0)"
    log "initiator workers=${n}"
    [[ "${n}" -ge "${NUM_DEV}" ]] && break
    sleep 2
  done
  sleep 2
  start_sg nixlbench-b target
  wait_job nixlbench-a uccl-sg 3600
  wait_job nixlbench-b uccl-sg 3600
  kubectl -n "${NS}" exec nixlbench-a -- cat /tmp/uccl-sg.log >"${RESULTS}/uccl-sg-a.log" || true
  kubectl -n "${NS}" exec nixlbench-b -- cat /tmp/uccl-sg.log >"${RESULTS}/uccl-sg-b.log" || true
  kubectl -n "${NS}" exec nixlbench-a -- \
    cat /tmp/nixlbench-sg-logs/rank-initiator-0.log >"${RESULTS}/uccl-sg-rank0.log" 2>/dev/null || true
  log "SG results (rank0):"
  grep -E '^[0-9]|Block Size|Aggregate|B/W|Backend|Mode |failed|ERROR' \
    "${RESULTS}/uccl-sg-rank0.log" "${RESULTS}/uccl-sg-a.log" 2>/dev/null | tail -40 || true
fi

if [[ "${RUN_MG}" == "1" ]]; then
  log "UCCL MG"
  clear_etcd
  kubectl -n "${NS}" exec nixlbench-a -- bash -lc 'killall -9 nixlbench 2>/dev/null || true' || true
  kubectl -n "${NS}" exec nixlbench-b -- bash -lc 'killall -9 nixlbench 2>/dev/null || true' || true
  sleep 1
  start_mg nixlbench-a
  sleep 2
  start_mg nixlbench-b
  wait_job nixlbench-a uccl-mg 3600
  wait_job nixlbench-b uccl-mg 3600
  kubectl -n "${NS}" exec nixlbench-a -- cat /tmp/uccl-mg.log >"${RESULTS}/uccl-mg-a.log" || true
  kubectl -n "${NS}" exec nixlbench-b -- cat /tmp/uccl-mg.log >"${RESULTS}/uccl-mg-b.log" || true
  log "MG results (A):"
  grep -E '^[0-9]|Block Size|B/W|Backend|Mode |Selected backend|failed|ERROR' \
    "${RESULTS}/uccl-mg-a.log" | tail -35 || true
fi

echo DONE >"${RESULTS}/uccl-suite.done"
log "=== UCCL suite SUCCESS === logs in ${RESULTS}/uccl-*.log"
