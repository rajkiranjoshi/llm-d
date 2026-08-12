#!/usr/bin/env bash
# ISL sweep benchmark for LIBFABRIC/EFA on EKS (or UCX/IB on CoreWeave).
# Runs OSL=1 benchmarks at multiple ISL values, saving logs after each run.
#
# Usage:
#   cd guides/pd-disaggregation
#   bash posting-overhead-analysis/experiment/run-isl-sweep.sh [BACKEND_LABEL] [NUM_REQUESTS] [MAX_CONCURRENCY]
#
# Example:
#   bash posting-overhead-analysis/experiment/run-isl-sweep.sh libfabric-efa 300 32
#   bash posting-overhead-analysis/experiment/run-isl-sweep.sh ucx-ib 300 32
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
NUM_REQUESTS_BASE="${2:-300}"
MC="${3:-32}"
OSL=1

ISLS=(1024 2048 4096 8192 16384 24000)

# Scale up requests for small ISLs to ensure enough metric samples (10s windows).
# Target: at least ~60s of runtime so we get 5+ metric windows.
requests_for_isl() {
  local isl=$1
  if   [ "$isl" -le 1024 ]; then echo $(( NUM_REQUESTS_BASE * 5 ))
  elif [ "$isl" -le 2048 ]; then echo $(( NUM_REQUESTS_BASE * 3 ))
  elif [ "$isl" -le 4096 ]; then echo $(( NUM_REQUESTS_BASE * 2 ))
  else echo "$NUM_REQUESTS_BASE"
  fi
}

OUTDIR="posting-overhead-analysis/benchmark-logs/isl-sweep-${BACKEND}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTDIR"

NAMESPACE="${NAMESPACE:-$(whoami)-dev}"
KN="kubectl -n $NAMESPACE"
echo "Using NAMESPACE=$NAMESPACE"

echo "========================================"
echo "ISL Sweep: ${BACKEND}"
echo "ISLs: ${ISLS[*]}"
echo "OSL: ${OSL}  MC: ${MC}  Base requests: ${NUM_REQUESTS_BASE} (scaled up for small ISLs)"
echo "Output: ${OUTDIR}"
echo "========================================"

SUMMARY_FILE="$OUTDIR/summary.md"
cat > "$SUMMARY_FILE" <<HEADER
# ISL Sweep Results: ${BACKEND}

| ISL | Descriptors (est.) | Data/xfer (est.) | Avg Post (ms) | Avg Xfer (ms) | Post/Xfer % | Throughput (GB/s) |
|---|---|---|---|---|---|---|
HEADER

PREV_KV_LINE_COUNT=0

for ISL in "${ISLS[@]}"; do
  NUM_REQUESTS=$(requests_for_isl "$ISL")

  echo ""
  echo "========================================"
  echo "Running ISL=${ISL}, OSL=${OSL}, MC=${MC}, N=${NUM_REQUESTS}"
  echo "========================================"

  # Record current KV metric line count BEFORE the benchmark so we can
  # extract only the NEW lines afterwards (the decode pod accumulates logs
  # across ISL runs — without this, kv-metrics files are contaminated with
  # data from previous ISLs).
  PREV_KV_LINE_COUNT=$($KN logs -l llm-d.ai/role=decode -c vllm --tail=10000 2>/dev/null \
    | grep -c "KV Transfer metrics" || echo 0)

  just benchmark "$MC" "$NUM_REQUESTS" "$ISL" "$OSL" \
    2>&1 | tee "$OUTDIR/benchmark-isl${ISL}.txt"

  echo "Saving decode pod logs..."
  $KN logs -l llm-d.ai/role=decode -c vllm --tail=10000 \
    > "$OUTDIR/decode-isl${ISL}.log" 2>&1 || true

  echo "Saving prefill pod logs..."
  $KN logs -l llm-d.ai/role=prefill -c vllm --tail=10000 \
    > "$OUTDIR/prefill-isl${ISL}.log" 2>&1 || true

  # Extract ONLY the KV transfer metrics from THIS ISL run by skipping lines
  # that existed before the benchmark started.
  echo "Extracting KV transfer metrics (this ISL only)..."
  grep "KV Transfer metrics" "$OUTDIR/decode-isl${ISL}.log" \
    | tail -n +$((PREV_KV_LINE_COUNT + 1)) \
    > "$OUTDIR/kv-metrics-isl${ISL}.txt" 2>/dev/null || true

  SAMPLE_COUNT=$(wc -l < "$OUTDIR/kv-metrics-isl${ISL}.txt" | tr -d ' ')
  echo "  ${SAMPLE_COUNT} metric samples collected"

  # Parse steady-state averages (skip first sample as warmup if we have enough)
  if [ "$SAMPLE_COUNT" -ge 1 ]; then
    SKIP_LINES=1
    [ "$SAMPLE_COUNT" -le 2 ] && SKIP_LINES=0
    tail -n +$((SKIP_LINES + 1)) "$OUTDIR/kv-metrics-isl${ISL}.txt" | \
    python3 -c "
import sys, re

lines = sys.stdin.readlines()
xfer_times, post_times, throughputs, descs, mbs = [], [], [], [], []
for line in lines:
    m = re.search(r'Avg xfer time \(ms\)=([0-9.]+).*Avg post time \(ms\)=([0-9.]+).*Avg MB per transfer=([0-9.]+).*Throughput \(MB/s\)=([0-9.]+).*Avg number of descriptors=([0-9.]+)', line)
    if m:
        xfer_times.append(float(m.group(1)))
        post_times.append(float(m.group(2)))
        mbs.append(float(m.group(3)))
        throughputs.append(float(m.group(4)))
        descs.append(float(m.group(5)))

if xfer_times:
    avg_xfer = sum(xfer_times) / len(xfer_times)
    avg_post = sum(post_times) / len(post_times)
    avg_tp = sum(throughputs) / len(throughputs)
    avg_desc = sum(descs) / len(descs)
    avg_mb = sum(mbs) / len(mbs)
    ratio = (avg_post / avg_xfer * 100) if avg_xfer > 0 else 0
    tp_gbs = avg_tp / 1024
    data_mb = avg_mb
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
