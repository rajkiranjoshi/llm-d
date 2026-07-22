#!/usr/bin/env bash
# Host orchestrator: sweep NUM_DEV (NIXL agents / GPUs per side) at fixed msg size,
# LIBFABRIC + UCCL, with Prometheus whole-node CPU avg/max.
#
# Env:
#   NS, RESULTS, PROM_URL, PROM_INSECURE, IDLE_BASELINE_S
#   MSG_MIB=64 (fixed transfer size)
#   NUM_DEVS="1 2 3 4"  (space-separated)
#   BACKENDS="LIBFABRIC UCCL"
set -euo pipefail

NS="${NS:-raj-nixlbench}"
RESULTS="${RESULTS:-/tmp/nixlbench-results}"
PROM_URL="${PROM_URL:-https://127.0.0.1:9090}"
PROM_INSECURE="${PROM_INSECURE:-1}"
IDLE_BASELINE_S="${IDLE_BASELINE_S:-30}"
MSG_MIB="${MSG_MIB:-64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default 1 2 4: NUM_DEV=3 needs total_buffer_size divisible by 3 (nixlbench default 8GiB is not).
# shellcheck disable=SC2206
NUM_DEVS=(${NUM_DEVS:-1 2 4})
# shellcheck disable=SC2206
BACKENDS=(${BACKENDS:-LIBFABRIC UCCL})

mkdir -p "${RESULTS}"
CSV="${RESULTS}/sg-ndev-cpu-suite.csv"
MD="${RESULTS}/sg-ndev-cpu-suite.md"
LOG="${RESULTS}/sg-ndev-cpu-suite-host.log"
DONE="${RESULTS}/sg-ndev-cpu-suite.done"

log() { echo "[sg-ndev $(date -u +%H:%M:%SZ)] $*"; }

curl_prom() {
  local path="$1"
  shift
  local args=(-sk --max-time 30)
  [[ "${PROM_INSECURE}" == "1" ]] || args=(-s --max-time 30 --cacert "${PROM_CA:-/tmp/prometheus-ca.crt}")
  curl "${args[@]}" --get "${PROM_URL}${path}" "$@"
}

ensure_prom() {
  if curl_prom /api/v1/status/buildinfo >/dev/null 2>&1; then
    return 0
  fi
  log "Prometheus not reachable at ${PROM_URL}; starting port-forward"
  pkill -f 'port-forward.*llmd-kube-prometheus-stack-prometheus' 2>/dev/null || true
  sleep 1
  nohup kubectl -n llm-d-monitoring port-forward \
    svc/llmd-kube-prometheus-stack-prometheus 9090:9090 \
    >/tmp/prom-pf.log 2>&1 &
  echo $! >/tmp/prom-pf.pid
  for i in $(seq 1 30); do
    sleep 1
    if curl_prom /api/v1/status/buildinfo >/dev/null 2>&1; then
      log "Prometheus port-forward ready (pid $(cat /tmp/prom-pf.pid))"
      return 0
    fi
  done
  log "ERROR: Prometheus still unreachable; see /tmp/prom-pf.log"
  return 1
}

resolve_instances() {
  NODE_A="$(kubectl -n "${NS}" get pod nixlbench-a -o jsonpath='{.spec.nodeName}')"
  NODE_B="$(kubectl -n "${NS}" get pod nixlbench-b -o jsonpath='{.spec.nodeName}')"
  local ip_a ip_b
  ip_a="$(kubectl get node "${NODE_A}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
  ip_b="$(kubectl get node "${NODE_B}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
  INST_A="${ip_a}:9100"
  INST_B="${ip_b}:9100"
  log "initiator node=${NODE_A} instance=${INST_A}"
  log "target    node=${NODE_B} instance=${INST_B}"
}

query_cpu_avg_max() {
  local instance="$1" t0="$2" t1="$3"
  ensure_prom || true
  local end=$((t1 + 15)) start=$t0 step=15
  if (( end - start < 60 )); then start=$((end - 60)); fi
  local q="100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\",instance=\"${instance}\"}[1m])))"
  local body
  body="$(curl_prom /api/v1/query_range \
    --data-urlencode "query=${q}" \
    --data-urlencode "start=${start}" \
    --data-urlencode "end=${end}" \
    --data-urlencode "step=${step}" 2>/dev/null || true)"
  printf '%s' "${body}" | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw:
  print("nan nan"); sys.exit(0)
try:
  d=json.loads(raw)
except Exception:
  print("nan nan"); sys.exit(0)
if d.get("status")!="success":
  print("nan nan"); sys.exit(0)
res=d.get("data",{}).get("result") or []
if not res:
  print("nan nan"); sys.exit(0)
vals=[float(v[1]) for v in res[0]["values"] if v[1] not in ("NaN","+Inf","-Inf")]
if not vals:
  print("nan nan"); sys.exit(0)
print(f"{sum(vals)/len(vals):.3f} {max(vals):.3f}")
'
}

query_cpu_instant() {
  local instance="$1"
  ensure_prom || true
  local q="100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\",instance=\"${instance}\"}[1m])))"
  local body
  body="$(curl_prom /api/v1/query --data-urlencode "query=${q}" 2>/dev/null || true)"
  printf '%s' "${body}" | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw:
  print("nan"); sys.exit(0)
try:
  d=json.loads(raw)
except Exception:
  print("nan"); sys.exit(0)
r=d.get("data",{}).get("result") or []
print("%.3f" % float(r[0]["value"][1]) if r else "nan")
'
}

copy_scripts() {
  local p
  for p in nixlbench-a nixlbench-b; do
    kubectl -n "${NS}" exec "$p" -- mkdir -p /tmp/nixlbench-scripts
    kubectl -n "${NS}" cp "${SCRIPT_DIR}/run-bench-sg.sh" "${p}:/tmp/nixlbench-scripts/run-bench-sg.sh"
    kubectl -n "${NS}" exec "$p" -- chmod +x /tmp/nixlbench-scripts/run-bench-sg.sh
  done
}

clear_etcd() {
  kubectl -n "${NS}" exec deploy/etcd -- \
    etcdctl --endpoints=http://127.0.0.1:2379 del --prefix xferbench >/dev/null 2>&1 || true
}

kill_bench() {
  kubectl -n "${NS}" exec nixlbench-a -- bash -lc 'killall -9 nixlbench 2>/dev/null || true' || true
  kubectl -n "${NS}" exec nixlbench-b -- bash -lc 'killall -9 nixlbench 2>/dev/null || true' || true
  sleep 2
}

count_workers() {
  local pod="$1" n
  n="$(kubectl -n "${NS}" exec "${pod}" -- bash -lc \
    'ps -eo stat,cmd | grep "[n]ixlbench --" | grep -v defunct | grep -c . || true' \
    2>/dev/null | tr -d ' \n' || true)"
  echo "${n:-0}"
}

start_sg() {
  local pod="$1" role="$2" backend="$3" group="$4" bytes="$5" num_dev="$6"
  kubectl -n "${NS}" exec "${pod}" -- bash -lc "
    cat > /tmp/launch-sg-cpu.sh <<EOS
#!/usr/bin/env bash
set -euo pipefail
export BACKEND=${backend}
export ROLE=${role}
export NUM_DEV=${num_dev}
export BENCH_GROUP=${group}
export EXTRA_ARGS='--start_block_size=${bytes} --max_block_size=${bytes}'
exec bash /tmp/nixlbench-scripts/run-bench-sg.sh
EOS
    chmod +x /tmp/launch-sg-cpu.sh
    : > /tmp/sg-cpu.log
    nohup /tmp/launch-sg-cpu.sh >>/tmp/sg-cpu.log 2>&1 </dev/null &
    echo \$! > /tmp/sg-cpu.pid
    sleep 2
    sleep 1
    if kill -0 \"\$(cat /tmp/sg-cpu.pid)\" 2>/dev/null; then
      echo started \$(cat /tmp/sg-cpu.pid) role=${role} backend=${backend} num_dev=${num_dev}
    else
      # Workers may exit fast on config errors; still report (caller continues).
      echo LAUNCH_EXITED
      cat /tmp/sg-cpu.log || true
    fi
  "
}

wait_sg_done() {
  local timeout_s="${1:-2400}"
  local i=0 na nb seen_workers=0 idle_polls=0
  while (( i < timeout_s )); do
    na=$(count_workers nixlbench-a); na=${na:-0}
    nb=$(count_workers nixlbench-b); nb=${nb:-0}
    if (( na > 0 || nb > 0 )); then
      seen_workers=1
      idle_polls=0
    fi
    if (( i % 30 == 0 )); then
      log "workers A=${na} B=${nb} t=${i}s"
    fi
    if (( seen_workers == 1 && na == 0 && nb == 0 )); then
      idle_polls=$((idle_polls + 1))
      local la lb
      la="$(kubectl -n "${NS}" exec nixlbench-a -- bash -lc 'pid=$(cat /tmp/sg-cpu.pid 2>/dev/null); ps -p ${pid:-0} >/dev/null 2>&1 && echo alive || echo dead' 2>/dev/null | tail -1)"
      lb="$(kubectl -n "${NS}" exec nixlbench-b -- bash -lc 'pid=$(cat /tmp/sg-cpu.pid 2>/dev/null); ps -p ${pid:-0} >/dev/null 2>&1 && echo alive || echo dead' 2>/dev/null | tail -1)"
      if [[ "${la}" == dead && "${lb}" == dead ]]; then
        log "SG workers and launchers finished"
        return 0
      fi
      if (( idle_polls >= 3 )); then
        log "SG workers idle (launchers la=${la} lb=${lb}); continuing"
        return 0
      fi
    fi
    sleep 5
    i=$((i + 5))
  done
  log "TIMEOUT waiting for SG"
  return 1
}

parse_bw() {
  # Optional 2nd arg: num_dev (used when Aggregate column is omitted for NUM_DEV=1)
  local num_dev="${1:-}"
  python3 -c '
import re,sys
text=sys.stdin.read()
ndev=int(sys.argv[1]) if len(sys.argv)>1 and sys.argv[1].isdigit() else 0
pat=re.compile(r"^(\d+)\s+(\d+)\s+([0-9.]+)\s+([0-9.]+)", re.M)
rows=pat.findall(text)
if not rows:
  print("nan nan"); sys.exit(0)
per=float(rows[-1][2]); fourth=float(rows[-1][3])
# NUM_DEV=1 often omits Aggregate; 4th field is then Avg Lat (us) ~hundreds–thousands
if fourth > 250:
  agg = per * ndev if ndev else per
else:
  agg = fourth
print(f"{per:.6f} {agg:.6f}")
' "${num_dev}"
}

tag_for() {
  local backend="$1" ndev="$2" mib="$3"
  case "${backend}" in
    LIBFABRIC) echo "lf-sg-n${ndev}-${mib}m" ;;
    UCCL) echo "uccl-sg-n${ndev}-${mib}m" ;;
    *) echo "${backend}-sg-n${ndev}-${mib}m" ;;
  esac
}

# --- main ---
rm -f "${DONE}"
: >"${LOG}"
log "=== SG NDEV CPU suite start MSG_MIB=${MSG_MIB} NUM_DEVS=${NUM_DEVS[*]} BACKENDS=${BACKENDS[*]} ==="
ensure_prom
resolve_instances
copy_scripts
kill_bench
clear_etcd

bytes=$((MSG_MIB * 1024 * 1024))

echo "backend,num_dev,msg_mib,per_stream_gbs,aggregate_gbs,cpu_init_avg,cpu_init_max,cpu_tgt_avg,cpu_tgt_max,t0,t1,duration_s" >"${CSV}"
cat >"${MD}" <<EOF
# SG nixlbench: CPU vs NUM_DEV (NIXL agents / GPUs per side)

VRAM READ, SG, fixed msg=${MSG_MIB} MiB. Each NUM_DEV = one NIXL agent per GPU on each pod (world = 2×NUM_DEV).

CPU = **whole-node** busy% from Prometheus node-exporter (\`node_cpu_seconds_total\`), not pod-scoped. Bench uses NUM_DEV/8 GPUs and ~4×NUM_DEV/32 EFA rails per node.

| Backend | NUM_DEV | Msg size | Per-stream (GB/s) | Aggregate (GB/s) | CPU init avg% | CPU init max% | CPU tgt avg% | CPU tgt max% |
|---------|--------:|----------|------------------:|-----------------:|--------------:|--------------:|-------------:|-------------:|
EOF

log "Idle baseline ${IDLE_BASELINE_S}s"
sleep "${IDLE_BASELINE_S}"
ensure_prom || true
idle_a="$(query_cpu_instant "${INST_A}")"
idle_b="$(query_cpu_instant "${INST_B}")"
log "idle CPU% init=${idle_a} tgt=${idle_b}"
echo "idle,0,${MSG_MIB},nan,nan,${idle_a},${idle_a},${idle_b},${idle_b},,,${IDLE_BASELINE_S}" >>"${CSV}"
echo "| *(idle baseline)* | — | ${MSG_MIB} MiB | — | — | ${idle_a} | ${idle_a} | ${idle_b} | ${idle_b} |" >>"${MD}"

for backend in "${BACKENDS[@]}"; do
  if [[ "${backend}" == "UCCL" ]]; then
    kubectl -n "${NS}" exec nixlbench-a -- bash -lc \
      'test -f /usr/local/nixlbench/uccl-env.sh && test -e /opt/uccl-p2p/nixl-plugins-cu12/libplugin_UCCL.so' \
      || { log "ERROR: UCCL not installed on nixlbench-a"; exit 1; }
  fi
  for ndev in "${NUM_DEVS[@]}"; do
    tag="$(tag_for "${backend}" "${ndev}" "${MSG_MIB}")"
    log "=== ${backend} NUM_DEV=${ndev} ${MSG_MIB} MiB (${tag}) ==="
    ensure_prom || true
    kill_bench
    clear_etcd
    sleep 2

    t0="$(date -u +%s)"
    start_sg nixlbench-a initiator "${backend}" "${tag}" "${bytes}" "${ndev}"
    for i in $(seq 1 40); do
      n="$(count_workers nixlbench-a)"; n=${n:-0}
      [[ "${n}" -ge "${ndev}" ]] && break
      sleep 2
    done
    sleep 2
    start_sg nixlbench-b target "${backend}" "${tag}" "${bytes}" "${ndev}"
    wait_sg_done 2400 || log "WARN: wait_sg_done timed out for ${tag}"
    t1="$(date -u +%s)"
    dur=$((t1 - t0))
    log "wall ${dur}s t0=${t0} t1=${t1}"

    for attempt in 1 2 3 4 5; do
      kubectl -n "${NS}" exec nixlbench-a -- cat /tmp/sg-cpu.log >"${RESULTS}/${tag}-a.log" 2>/dev/null || true
      kubectl -n "${NS}" exec nixlbench-b -- cat /tmp/sg-cpu.log >"${RESULTS}/${tag}-b.log" 2>/dev/null || true
      kubectl -n "${NS}" exec nixlbench-a -- \
        cat /tmp/nixlbench-sg-logs/rank-initiator-0.log >"${RESULTS}/${tag}-rank0.log" 2>/dev/null || true
      if [[ -s "${RESULTS}/${tag}-rank0.log" || -s "${RESULTS}/${tag}-a.log" ]]; then
        break
      fi
      log "WARN: log collect empty (attempt ${attempt}); retry in 15s"
      sleep 15
    done

    bw="$(parse_bw "${ndev}" <"${RESULTS}/${tag}-rank0.log" 2>/dev/null || echo "nan nan")"
    per_s="$(echo "${bw}" | awk '{print $1}')"
    agg="$(echo "${bw}" | awk '{print $2}')"
    if [[ "${per_s}" == "nan" && -s "${RESULTS}/${tag}-a.log" ]]; then
      bw="$(parse_bw "${ndev}" <"${RESULTS}/${tag}-a.log" 2>/dev/null || echo "nan nan")"
      per_s="$(echo "${bw}" | awk '{print $1}')"
      agg="$(echo "${bw}" | awk '{print $2}')"
    fi
    log "BW per_stream=${per_s} aggregate=${agg}"

    sleep 20
    ensure_prom || log "WARN: Prometheus unreachable; CPU will be nan"
    read -r cpu_ia cpu_im <<<"$(query_cpu_avg_max "${INST_A}" "${t0}" "${t1}")"
    read -r cpu_ta cpu_tm <<<"$(query_cpu_avg_max "${INST_B}" "${t0}" "${t1}")"
    log "CPU init avg/max=${cpu_ia}/${cpu_im} tgt avg/max=${cpu_ta}/${cpu_tm}"

    echo "${backend},${ndev},${MSG_MIB},${per_s},${agg},${cpu_ia},${cpu_im},${cpu_ta},${cpu_tm},${t0},${t1},${dur}" >>"${CSV}"
    printf '| %s | %s | %s MiB | %s | %s | %s | %s | %s | %s |\n' \
      "${backend}" "${ndev}" "${MSG_MIB}" "${per_s}" "${agg}" \
      "${cpu_ia}" "${cpu_im}" "${cpu_ta}" "${cpu_tm}" >>"${MD}"
  done
done

echo DONE >"${DONE}"
log "=== SUCCESS === CSV=${CSV} MD=${MD}"
cat "${MD}"
