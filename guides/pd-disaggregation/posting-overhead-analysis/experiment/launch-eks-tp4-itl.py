#!/usr/bin/env python3
"""
Launch a Cursor SDK agent to run the ITL (Inter-Token Latency) experiment
on EKS with TP4 configuration.

Measures the impact of LIBFABRIC posting overhead on ITL with MC=8, OSL=512
at ISL=4096 and ISL=24000.

Usage:
    tmux attach -t cursor-agent-eks
    source ~/.env && python3 launch-eks-tp4-itl.py
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

PROMPT = """
You are running an ITL (Inter-Token Latency) experiment for P/D disaggregated inference
on EKS with TP4 configuration. This measures how LIBFABRIC/EFA posting overhead impacts
decode-side inter-token latency under concurrent load.

This is a REAL deployment on a REAL cluster. Execute commands carefully.

## Environment
- KUBECONFIG: %(kubeconfig)s
- Namespace: raj-dev
- Workspace: %(workspace)s
- Working directory: %(workspace)s/guides/pd-disaggregation

## Experiment Parameters
- **MC=8** (max concurrency — 8 concurrent requests generating output)
- **OSL=512** (output sequence length — each request generates 512 output tokens)
- **NUM_REQUESTS=100** (total requests per ISL point)
- **ISL values: 4096, 24000**
- We measure Mean ITL, Median ITL, P99 ITL from vllm bench serve output

## Your Task — Execute These Steps in Order

### Step 1: Verify Namespace is Clean
Before deploying, check that no leftover resources exist from a previous run:
```bash
export KUBECONFIG=%(kubeconfig)s
kubectl -n raj-dev get pods
```
If pods exist, wait for them to terminate. If they are stuck, delete them.

### Step 2: Deploy the P/D Stack with TP4
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

### Step 3: Wait for Pods to Be Ready
Check every 5 minutes. All pods (prefill, decode, EPP) must be Ready.
```bash
export KUBECONFIG=%(kubeconfig)s
kubectl -n raj-dev get pods -o wide
kubectl -n raj-dev wait --for=condition=Ready pod -l llm-d.ai/role=decode --timeout=1200s
kubectl -n raj-dev wait --for=condition=Ready pod -l llm-d.ai/role=prefill --timeout=1200s
```

If pods crash or show OOM / max_model_len errors:
1. Edit ms-pd/values_eks_rdma.yaml, change --max-model-len to "24576" or "16384"
2. Re-deploy with `just deploy`
3. If max-model-len drops below 24000, skip ISL=24000

### Step 4: Deploy Poker Pod
```bash
export KUBECONFIG=%(kubeconfig)s
kubectl apply -f %(workspace)s/poker/poker.yaml -n raj-dev
kubectl -n raj-dev wait --for=condition=Ready pod/poker --timeout=120s
```

### Step 5: Sync Poker Justfile
```bash
export KUBECONFIG=%(kubeconfig)s
export NAMESPACE=raj-dev
cd %(workspace)s/guides/pd-disaggregation
just _sync-poker-justfile
```

### Step 6: Create Output Directory
```bash
cd %(workspace)s/guides/pd-disaggregation
OUTDIR="posting-overhead-analysis/benchmark-logs/itl-libfabric-efa-tp4-$(date +%%Y%%m%%d-%%H%%M%%S)"
mkdir -p "$OUTDIR"
echo "Output: $OUTDIR"
```

### Step 7: Run ISL=4096 Benchmark (MC=8, 100 reqs, OSL=512)
Run ONE benchmark at a time. Wait for it to finish completely before starting the next.

```bash
export KUBECONFIG=%(kubeconfig)s
export NAMESPACE=raj-dev
cd %(workspace)s/guides/pd-disaggregation
just benchmark 8 100 4096 512 2>&1 | tee "$OUTDIR/benchmark-isl4096.txt"
```

After it completes, collect ALL logs:
```bash
kubectl -n raj-dev logs -l llm-d.ai/role=decode -c vllm --tail=20000 > "$OUTDIR/decode-isl4096.log" 2>&1
kubectl -n raj-dev logs -l llm-d.ai/role=prefill -c vllm --tail=20000 > "$OUTDIR/prefill-isl4096.log" 2>&1
grep "KV Transfer metrics" "$OUTDIR/decode-isl4096.log" > "$OUTDIR/kv-metrics-isl4096.txt" 2>/dev/null
```

### Step 8: Run ISL=24000 Benchmark (MC=8, 100 reqs, OSL=512)
```bash
export KUBECONFIG=%(kubeconfig)s
export NAMESPACE=raj-dev
cd %(workspace)s/guides/pd-disaggregation
just benchmark 8 100 24000 512 2>&1 | tee "$OUTDIR/benchmark-isl24000.txt"
```

After it completes, collect ALL logs:
```bash
kubectl -n raj-dev logs -l llm-d.ai/role=decode -c vllm --tail=20000 > "$OUTDIR/decode-isl24000.log" 2>&1
kubectl -n raj-dev logs -l llm-d.ai/role=prefill -c vllm --tail=20000 > "$OUTDIR/prefill-isl24000.log" 2>&1
grep "KV Transfer metrics" "$OUTDIR/decode-isl24000.log" > "$OUTDIR/kv-metrics-isl24000.txt" 2>/dev/null
```

### Step 9: Parse Results
Extract ITL statistics from the benchmark output AND KV transfer metrics from decode logs.

```bash
for ISL in 4096 24000; do
  echo "=== ISL=$ISL ==="
  echo "--- ITL Metrics ---"
  grep -i "itl" "$OUTDIR/benchmark-isl${ISL}.txt" || echo "No ITL lines found"
  echo ""
  echo "--- Benchmark Summary ---"
  grep -E "(Mean|Median|P99|Throughput|Total|Successful|Failed)" "$OUTDIR/benchmark-isl${ISL}.txt" || true
  echo ""
  echo "--- KV Transfer Metrics ---"
  KV_FILE="$OUTDIR/kv-metrics-isl${ISL}.txt"
  if [ -s "$KV_FILE" ]; then
    SAMPLE_COUNT=$(wc -l < "$KV_FILE" | tr -d ' ')
    echo "KV samples: $SAMPLE_COUNT"
    SKIP=1
    [ "$SAMPLE_COUNT" -le 2 ] && SKIP=0
    tail -n +$((SKIP + 1)) "$KV_FILE" | python3 -c "
import sys, re
lines = sys.stdin.readlines()
xfer_times, post_times = [], []
for line in lines:
    m = re.search(r'Avg xfer time \(ms\)=([0-9.]+).*Avg post time \(ms\)=([0-9.]+)', line)
    if m:
        xfer_times.append(float(m.group(1)))
        post_times.append(float(m.group(2)))
if xfer_times:
    print(f'  Avg Post: {sum(post_times)/len(post_times):.2f} ms')
    print(f'  Avg Xfer: {sum(xfer_times)/len(xfer_times):.2f} ms')
    print(f'  Samples:  {len(xfer_times)}')
"
  else
    echo "No KV metrics found"
  fi
  echo ""
done
```

### Step 10: Save Pod/Node Info
```bash
export KUBECONFIG=%(kubeconfig)s
kubectl -n raj-dev get pods -o wide > "$OUTDIR/pod-placement.txt"
kubectl get nodes -o wide > "$OUTDIR/node-info.txt"
```

### Step 11: Tear Down
```bash
export KUBECONFIG=%(kubeconfig)s
export NAMESPACE=raj-dev
export HELMFILE_ENV=eks_rdma
cd %(workspace)s/guides/pd-disaggregation
helmfile -f helmfile.yaml.gotmpl destroy -e eks_rdma -n raj-dev
kubectl delete -f httproute.yaml -n raj-dev --ignore-not-found=true
kubectl -n raj-dev delete pod poker --ignore-not-found=true
```

Verify cleanup:
```bash
kubectl -n raj-dev get pods
```

### Step 12: Final Summary
Print this EXACT format as your last output:

```
=== EKS TP4 ITL EXPERIMENT — FINAL REPORT ===

CONFIGURATION:
- Cluster: EKS (LIBFABRIC/EFA)
- Model: RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic
- TP: 4, EFA NICs: 16, Replicas: 1P + 1D
- max-model-len: <value used>
- Benchmark: MC=8, 100 requests, OSL=512
- Prefill node: <node name>
- Decode node: <node name>

RESULTS TABLE:
| ISL   | Mean ITL (ms) | Median ITL (ms) | P99 ITL (ms) | Avg Post (ms) | Avg Xfer (ms) |
|-------|---------------|-----------------|--------------|----------------|----------------|
| 4096  | <value>       | <value>         | <value>      | <value>        | <value>        |
| 24000 | <value>       | <value>         | <value>      | <value>        | <value>        |

COMPARISON WITH TP8 RESULTS (LIBFABRIC/EFA):
TP8 ISL=4096:  Mean ITL=8.82ms, Median=8.70ms, P99=16.97ms
TP8 ISL=24000: Mean ITL=11.76ms, Median=10.65ms, P99=84.18ms

TROUBLESHOOTING LOG:
- <any issues encountered and how resolved>

OUTPUT LOCATION:
- <full path to results directory>
- List key files and their sizes

TEARDOWN STATUS:
- Confirm all resources deleted
```

## Important Notes
- Always set KUBECONFIG=%(kubeconfig)s before any kubectl/helmfile/just command.
- Run benchmarks ONE AT A TIME. Never overlap.
- Save ALL raw logs — benchmark output, decode logs, prefill logs, KV metrics.
- The ITL metrics come from vllm bench serve output, NOT from KV transfer metrics.
- The KV transfer metrics are collected for reference (to correlate post time with ITL impact).
""" % {"kubeconfig": KUBECONFIG_EKS, "workspace": WORKSPACE}

print("=" * 60)
print("EKS TP4 ITL Experiment — SDK Agent Launcher")
print("=" * 60)
print(f"API Key: {api_key[:10]}...")
print(f"Model: claude-opus-4-6")
print(f"Workspace: {WORKSPACE}")
print(f"KUBECONFIG: {KUBECONFIG_EKS}")
print(f"Experiment: MC=8, OSL=512, ISL=4096+24000")
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

    if result.status == "error":
        print("ERROR: Agent encountered an error. Check output above.")
        sys.exit(2)
