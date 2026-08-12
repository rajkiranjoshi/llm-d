#!/usr/bin/env python3
"""
Re-run ISL=1024 and ISL=24000 on EKS with TP4 to replace corrupted/missing data.
Run this inside the cursor-agent-eks tmux session.
"""

import os
import sys
import time
from cursor_sdk import Agent, AgentOptions, LocalAgentOptions

api_key = os.environ.get("CURSOR_API_KEY")
if not api_key:
    env_path = os.path.expanduser("~/.env")
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if "CURSOR_API_KEY=" in line:
                    api_key = line.split("=", 1)[1].strip('"').strip("'")
                    break

if not api_key:
    print("ERROR: CURSOR_API_KEY not found")
    sys.exit(1)

WORKSPACE = "/mnt/nvme5n1p1/rajkiranjoshi/workspace/llm-d"
KUBECONFIG_EKS = "/mnt/nvme5n1p1/rajkiranjoshi/.kube/config.eks"
ORIGINAL_RESULTS_DIR = "guides/pd-disaggregation/posting-overhead-analysis/benchmark-logs/isl-sweep-libfabric-efa-20260806-204846"

PROMPT = """
You are re-running 2 ISL data points on EKS that were corrupted/missing from the original sweep.
This is a REAL deployment on a REAL cluster.

## Environment
- KUBECONFIG: %(kubeconfig)s
- Namespace: raj-dev
- Workspace: %(workspace)s
- Working directory: %(workspace)s/guides/pd-disaggregation

## Context
The original ISL sweep completed but:
- ISL=1024: Only 1 metric sample (too few requests, completed too fast for multiple metric windows)
- ISL=24000: Data was contaminated by an overlapping ISL=1024 benchmark running concurrently

We need clean re-runs of just these 2 points.

## Your Task

### Step 1: Deploy the P/D Stack with TP4
```bash
export KUBECONFIG=%(kubeconfig)s
export NAMESPACE=raj-dev
export HELMFILE_ENV=eks_rdma
export PREFILL_TP=4
export DECODE_TP=4
export PREFILL_REPLICAS=1
export DECODE_REPLICAS=1
cd %(workspace)s/guides/pd-disaggregation
just deploy
```

### Step 2: Wait for Pods to Be Ready
Check every 5 minutes. All pods (prefill, decode, EPP) must be Ready before proceeding.
```bash
export KUBECONFIG=%(kubeconfig)s
kubectl -n raj-dev get pods -o wide
kubectl -n raj-dev wait --for=condition=Ready pod -l llm-d.ai/role=decode --timeout=1200s
kubectl -n raj-dev wait --for=condition=Ready pod -l llm-d.ai/role=prefill --timeout=1200s
```

### Step 3: Deploy Poker Pod
```bash
export KUBECONFIG=%(kubeconfig)s
kubectl apply -f %(workspace)s/poker/poker.yaml -n raj-dev
kubectl -n raj-dev wait --for=condition=Ready pod/poker --timeout=120s
```

### Step 4: Sync Poker Justfile
```bash
export KUBECONFIG=%(kubeconfig)s
export NAMESPACE=raj-dev
cd %(workspace)s/guides/pd-disaggregation
just _sync-poker-justfile
```

### Step 5: Create Output Directory
```bash
cd %(workspace)s/guides/pd-disaggregation
OUTDIR="posting-overhead-analysis/benchmark-logs/isl-rerun-libfabric-efa-$(date +%%Y%%m%%d-%%H%%M%%S)"
mkdir -p "$OUTDIR"
echo "Output: $OUTDIR"
```

### Step 6: Run ISL=1024 (1500 requests for enough metric samples)
Run ONE benchmark at a time. Wait for it to finish completely before starting the next.

```bash
export KUBECONFIG=%(kubeconfig)s
export NAMESPACE=raj-dev
cd %(workspace)s/guides/pd-disaggregation
just benchmark 32 1500 1024 1 2>&1 | tee "$OUTDIR/benchmark-isl1024.txt"
```

After it completes, collect logs:
```bash
kubectl -n raj-dev logs -l llm-d.ai/role=decode -c vllm --tail=10000 > "$OUTDIR/decode-isl1024.log" 2>&1
kubectl -n raj-dev logs -l llm-d.ai/role=prefill -c vllm --tail=10000 > "$OUTDIR/prefill-isl1024.log" 2>&1
grep "KV Transfer metrics" "$OUTDIR/decode-isl1024.log" > "$OUTDIR/kv-metrics-isl1024.txt" 2>/dev/null
```

### Step 7: Run ISL=24000 (150 requests to keep runtime reasonable)
```bash
export KUBECONFIG=%(kubeconfig)s
export NAMESPACE=raj-dev
cd %(workspace)s/guides/pd-disaggregation
just benchmark 32 150 24000 1 2>&1 | tee "$OUTDIR/benchmark-isl24000.txt"
```

After it completes, collect logs:
```bash
kubectl -n raj-dev logs -l llm-d.ai/role=decode -c vllm --tail=10000 > "$OUTDIR/decode-isl24000.log" 2>&1
kubectl -n raj-dev logs -l llm-d.ai/role=prefill -c vllm --tail=10000 > "$OUTDIR/prefill-isl24000.log" 2>&1
grep "KV Transfer metrics" "$OUTDIR/decode-isl24000.log" > "$OUTDIR/kv-metrics-isl24000.txt" 2>/dev/null
```

### Step 8: Parse Results
For each ISL (1024, 24000), compute steady-state averages from the KV metrics.
Skip the first metric sample as warmup ONLY if there are 3+ samples. Otherwise use all samples.

For each ISL, count lines in the kv-metrics file, then run a Python script to compute averages:
```bash
for ISL in 1024 24000; do
  METRICS_FILE="$OUTDIR/kv-metrics-isl${ISL}.txt"
  SAMPLE_COUNT=$(wc -l < "$METRICS_FILE" | tr -d ' ')
  echo "ISL=$ISL: $SAMPLE_COUNT metric samples"
  if [ "$SAMPLE_COUNT" -ge 1 ]; then
    SKIP=1
    [ "$SAMPLE_COUNT" -le 2 ] && SKIP=0
    tail -n +$((SKIP + 1)) "$METRICS_FILE" | python3 -c "
import sys, re
lines = sys.stdin.readlines()
xfer_times, post_times, throughputs = [], [], []
for line in lines:
    m = re.search(r'Avg xfer time \(ms\)=([0-9.]+).*Avg post time \(ms\)=([0-9.]+).*Throughput \(MB/s\)=([0-9.]+)', line)
    if m:
        xfer_times.append(float(m.group(1)))
        post_times.append(float(m.group(2)))
        throughputs.append(float(m.group(3)))
if xfer_times:
    avg_xfer = sum(xfer_times)/len(xfer_times)
    avg_post = sum(post_times)/len(post_times)
    avg_tp = sum(throughputs)/len(throughputs)
    ratio = (avg_post/avg_xfer*100) if avg_xfer > 0 else 0
    tp_gbs = avg_tp / 1024
    print(f'ISL=$ISL: Post={avg_post:.2f}ms, Xfer={avg_xfer:.2f}ms, Post/Xfer={ratio:.1f}%%, TP={tp_gbs:.2f} GB/s ({len(xfer_times)} samples)')
"
  fi
done
```

### Step 9: Save Pod/Node Info and Tear Down
```bash
export KUBECONFIG=%(kubeconfig)s
kubectl -n raj-dev get pods -o wide > "$OUTDIR/pod-placement.txt"
kubectl get nodes -o wide > "$OUTDIR/node-info.txt"

export NAMESPACE=raj-dev
export HELMFILE_ENV=eks_rdma
cd %(workspace)s/guides/pd-disaggregation
helmfile -f helmfile.yaml.gotmpl destroy -e eks_rdma -n raj-dev
kubectl delete -f httproute.yaml -n raj-dev --ignore-not-found=true
kubectl -n raj-dev delete pod poker --ignore-not-found=true
```

### Step 10: Final Summary
Print a concise report:

```
=== EKS TP4 ISL RERUN — FINAL REPORT ===

CONFIGURATION:
- Cluster: EKS (LIBFABRIC/EFA)
- Model: RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic
- TP: 4, EFA NICs: 16

RERUN RESULTS:
| ISL   | Post (ms) | Xfer (ms) | Post/Xfer %% | Throughput (GB/s) | Samples |
|-------|-----------|-----------|-------------|-------------------|---------|
(fill in for each ISL)

COMPARISON WITH ORIGINAL (for reference):
- Original ISL=1024: — (only 1 sample, skipped)
- Original ISL=24000: 54.25ms post, 60.11ms xfer (possibly contaminated)

OUTPUT LOCATION:
- <full path to rerun results directory>

TEARDOWN STATUS:
- Confirm all resources deleted
```

## Important Notes
- Always set KUBECONFIG=%(kubeconfig)s before any kubectl/helmfile/just command.
- Run benchmarks ONE AT A TIME. Never overlap. Wait for each to fully complete.
- OSL=1 is critical (posting overhead measurement).
- Tear down when done.
""" % {"kubeconfig": KUBECONFIG_EKS, "workspace": WORKSPACE}

print("=" * 60)
print("EKS TP4 ISL Rerun (1024 + 24000) — SDK Agent Launcher")
print("=" * 60)
print(f"API Key: {api_key[:10]}...")
print(f"Workspace: {WORKSPACE}")
print(f"KUBECONFIG: {KUBECONFIG_EKS}")
print()
print("Launching agent...")
print("=" * 60)
print()

start_time = time.time()

with Agent.create(
    AgentOptions(
        api_key=api_key,
        model="claude-opus-4-6",
        local=LocalAgentOptions(cwd=WORKSPACE),
    ),
) as agent:
    agent_id = agent.agent_id
    print(f"Agent ID: {agent_id}")
    print(f"Started at: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print()

    run = agent.send(PROMPT)

    print("--- Agent Output ---")
    for message in run.messages():
        if message.type == "assistant":
            for block in message.message.content:
                if block.type == "text":
                    print(block.text, end="", flush=True)

    result = run.wait()
    elapsed = time.time() - start_time

    print()
    print()
    print("=" * 60)
    print(f"Agent finished with status: {result.status}")
    print(f"Elapsed time: {elapsed/60:.1f} minutes")
    print(f"Agent ID: {agent_id}")
    print("=" * 60)
