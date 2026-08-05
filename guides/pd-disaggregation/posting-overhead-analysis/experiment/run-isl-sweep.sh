#!/usr/bin/env bash
# ISL sweep benchmark for LIBFABRIC/EFA on EKS (or UCX/IB on CoreWeave).
# Runs OSL=1 benchmarks at multiple ISL values, saving logs after each run.
#
# Usage:
#   cd guides/pd-disaggregation
#   bash run-isl-sweep.sh [BACKEND_LABEL] [NUM_REQUESTS] [MAX_CONCURRENCY]
#
# Example:
#   bash run-isl-sweep.sh libfabric-efa 300 32
#   bash run-isl-sweep.sh ucx-ib 300 32
#
# Prerequisites:
#   - Deployment is up and all pods are Ready
#   - Poker pod is running
#   - KUBECONFIG and NAMESPACE are set (via .env or environment)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source .env if present (same as Justfile's dotenv-load)
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

BACKEND="${1:-libfabric-efa}"
NUM_REQUESTS="${2:-300}"
MC="${3:-32}"
OSL=1

ISLS=(1024 2048 4096 8192 16384 24000)

OUTDIR="benchmark-logs/isl-sweep-${BACKEND}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTDIR"

NAMESPACE="${NAMESPACE:-$(whoami)-dev}"
KN="kubectl -n $NAMESPACE"
echo "Using NAMESPACE=$NAMESPACE"

echo "========================================"
echo "ISL Sweep: ${BACKEND}"
echo "ISLs: ${ISLS[*]}"
echo "OSL: ${OSL}  MC: ${MC}  Requests: ${NUM_REQUESTS}"
echo "Output: ${OUTDIR}"
echo "========================================"

SUMMARY_FILE="$OUTDIR/summary.md"
cat > "$SUMMARY_FILE" <<HEADER
# ISL Sweep Results: ${BACKEND}

| ISL | Descriptors (est.) | Data/xfer (est.) | Avg Post (ms) | Avg Xfer (ms) | Post/Xfer % | Throughput (GB/s) |
|---|---|---|---|---|---|---|
HEADER

for ISL in "${ISLS[@]}"; do
  echo ""
  echo "========================================"
  echo "Running ISL=${ISL}, OSL=${OSL}, MC=${MC}, N=${NUM_REQUESTS}"
  echo "========================================"

  just benchmark "$MC" "$NUM_REQUESTS" "$ISL" "$OSL" \
    2>&1 | tee "$OUTDIR/benchmark-isl${ISL}.txt"

  echo "Saving decode pod logs..."
  $KN logs -l llm-d.ai/role=decode -c vllm --tail=10000 \
    > "$OUTDIR/decode-isl${ISL}.log" 2>&1 || true

  echo "Saving prefill pod logs..."
  $KN logs -l llm-d.ai/role=prefill -c vllm --tail=10000 \
    > "$OUTDIR/prefill-isl${ISL}.log" 2>&1 || true

  # Extract KV transfer metrics from decode log (skip warmup = first sample)
  echo "Extracting KV transfer metrics..."
  grep "KV Transfer metrics" "$OUTDIR/decode-isl${ISL}.log" \
    > "$OUTDIR/kv-metrics-isl${ISL}.txt" 2>/dev/null || true

  SAMPLE_COUNT=$(wc -l < "$OUTDIR/kv-metrics-isl${ISL}.txt" | tr -d ' ')
  echo "  ${SAMPLE_COUNT} metric samples collected"

  # Parse steady-state averages (skip first sample = warmup)
  if [ "$SAMPLE_COUNT" -ge 2 ]; then
    tail -n +2 "$OUTDIR/kv-metrics-isl${ISL}.txt" | \
    python3 -c "
import sys, re

lines = sys.stdin.readlines()
xfer_times, post_times, throughputs, descs = [], [], [], []
for line in lines:
    m = re.search(r'Avg xfer time \(ms\)=([0-9.]+).*Avg post time \(ms\)=([0-9.]+).*Throughput \(MB/s\)=([0-9.]+).*Avg number of descriptors=([0-9.]+)', line)
    if m:
        xfer_times.append(float(m.group(1)))
        post_times.append(float(m.group(2)))
        throughputs.append(float(m.group(3)))
        descs.append(float(m.group(4)))

if xfer_times:
    avg_xfer = sum(xfer_times) / len(xfer_times)
    avg_post = sum(post_times) / len(post_times)
    avg_tp = sum(throughputs) / len(throughputs)
    avg_desc = sum(descs) / len(descs)
    ratio = (avg_post / avg_xfer * 100) if avg_xfer > 0 else 0
    tp_gbs = avg_tp / 1024
    data_mb = avg_desc * 160 / 5120  # scale from known 5120desc=160MB
    print(f'| {$ISL} | {avg_desc:.0f} | {data_mb:.0f} MB | {avg_post:.2f} | {avg_xfer:.2f} | {ratio:.1f}% | {tp_gbs:.2f} |')
    # Also write a machine-readable line
    with open('$OUTDIR/results.csv', 'a') as f:
        f.write(f'{$ISL},{avg_desc:.0f},{data_mb:.0f},{avg_post:.2f},{avg_xfer:.2f},{ratio:.1f},{tp_gbs:.2f},{len(xfer_times)}\n')
else:
    print(f'| {$ISL} | — | — | — | — | — | — |')
" >> "$SUMMARY_FILE"
  else
    echo "| ${ISL} | — | — | — | — | — | — |" >> "$SUMMARY_FILE"
  fi

  echo "  Done ISL=${ISL}"
  echo ""
  sleep 5
done

# Add CSV header
if [ -f "$OUTDIR/results.csv" ]; then
  sed -i.bak '1i\
ISL,Descriptors,Data_MB,Avg_Post_ms,Avg_Xfer_ms,Post_Xfer_Pct,Throughput_GBs,Samples' "$OUTDIR/results.csv" 2>/dev/null || \
  { echo "ISL,Descriptors,Data_MB,Avg_Post_ms,Avg_Xfer_ms,Post_Xfer_Pct,Throughput_GBs,Samples" | cat - "$OUTDIR/results.csv" > /tmp/csv_tmp && mv /tmp/csv_tmp "$OUTDIR/results.csv"; }
  rm -f "$OUTDIR/results.csv.bak"
fi

echo ""
echo "========================================"
echo "ISL Sweep Complete"
echo "========================================"
echo ""
echo "Results: $OUTDIR/summary.md"
echo "CSV:     $OUTDIR/results.csv"
echo ""
cat "$SUMMARY_FILE"
