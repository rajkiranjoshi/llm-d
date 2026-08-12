#!/usr/bin/env python3
"""
Re-run the ITL experiment on CoreWeave (UCX/IB) with TP4 to verify
whether the anomalous P99 ITL of 223-225 ms reproduces.

If the anomaly persists, the agent will investigate autonomously:
- Check decode pod logs for errors/warnings
- Check node utilization and co-tenancy
- Try different MC values or request counts
- Run the benchmark multiple times to see variance
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
KUBECONFIG_CW = "/mnt/nvme5n1p1/rajkiranjoshi/.kube/config.waldorf"

PROMPT = """
You are re-running the ITL experiment on CoreWeave (UCX/IB) with TP4 to investigate
an anomalous P99 ITL result. The previous run showed P99 ITL of 223-225 ms at both
ISL=4096 and ISL=24000, which is unexpectedly high — the TP8 results on the same
cluster showed P99 of only 11-14 ms.

This is a REAL deployment on a REAL cluster. Execute commands carefully.

## Environment
- KUBECONFIG: %(kubeconfig)s
- Namespace: rajjoshi-dev
- Workspace: %(workspace)s
- Working directory: %(workspace)s/guides/pd-disaggregation

## Previous Results (the anomaly)
| ISL   | Mean ITL (ms) | Median ITL (ms) | P99 ITL (ms) |
|-------|---------------|-----------------|--------------|
| 4096  | 10.10         | 8.04            | 223.50       |
| 24000 | 11.15         | 10.27           | 225.15       |

Mean and median look reasonable. P99 is anomalously high. Note that both ISLs
show almost identical P99 (~223-225 ms), which is suspicious — it suggests a
fixed-overhead tail event unrelated to ISL.

## Your Task

### Phase 1: Deploy and Run Baseline (same params as before)

#### Step 1: Deploy P/D Stack
```bash
export KUBECONFIG=%(kubeconfig)s
export NAMESPACE=rajjoshi-dev
export HELMFILE_ENV=coreweave
cd %(workspace)s/guides/pd-disaggregation
helmfile -f helmfile.yaml.gotmpl apply -e coreweave -n rajjoshi-dev
kubectl apply -f httproute.yaml -n rajjoshi-dev
```

#### Step 2: Wait for Pods
```bash
export KUBECONFIG=%(kubeconfig)s
kubectl -n rajjoshi-dev wait --for=condition=Ready pod -l llm-d.ai/role=decode --timeout=1200s
kubectl -n rajjoshi-dev wait --for=condition=Ready pod -l llm-d.ai/role=prefill --timeout=1200s
```

#### Step 3: Deploy Poker Pod + Sync
```bash
export KUBECONFIG=%(kubeconfig)s
kubectl apply -f %(workspace)s/poker/poker.yaml -n rajjoshi-dev
kubectl -n rajjoshi-dev wait --for=condition=Ready pod/poker --timeout=120s
export NAMESPACE=rajjoshi-dev
cd %(workspace)s/guides/pd-disaggregation
just _sync-poker-justfile
```

#### Step 4: Create Output Directory
```bash
cd %(workspace)s/guides/pd-disaggregation
OUTDIR="posting-overhead-analysis/benchmark-logs/itl-ucx-ib-tp4-rerun-$(date +%%Y%%m%%d-%%H%%M%%S)"
mkdir -p "$OUTDIR"
echo "Output: $OUTDIR"
```

#### Step 5: Record Node Placement & Cluster State
Before running benchmarks, capture the environment:
```bash
export KUBECONFIG=%(kubeconfig)s
kubectl -n rajjoshi-dev get pods -o wide > "$OUTDIR/pod-placement.txt"
kubectl get nodes -o wide > "$OUTDIR/node-info.txt"
kubectl top nodes > "$OUTDIR/node-utilization.txt" 2>/dev/null || true
```

#### Step 6: Run ISL=4096 Benchmark (MC=8, 100 reqs, OSL=512) — Run 1
```bash
export KUBECONFIG=%(kubeconfig)s
export NAMESPACE=rajjoshi-dev
cd %(workspace)s/guides/pd-disaggregation
just benchmark 8 100 4096 512 2>&1 | tee "$OUTDIR/benchmark-isl4096-run1.txt"
```

Collect logs:
```bash
kubectl -n rajjoshi-dev logs -l llm-d.ai/role=decode -c vllm --tail=20000 > "$OUTDIR/decode-isl4096-run1.log" 2>&1
kubectl -n rajjoshi-dev logs -l llm-d.ai/role=prefill -c vllm --tail=20000 > "$OUTDIR/prefill-isl4096-run1.log" 2>&1
grep "KV Transfer metrics" "$OUTDIR/decode-isl4096-run1.log" > "$OUTDIR/kv-metrics-isl4096-run1.txt" 2>/dev/null
```

Extract the ITL numbers. Check: is P99 > 100ms?

#### Step 7: Run ISL=24000 Benchmark (MC=8, 100 reqs, OSL=512) — Run 1
```bash
export KUBECONFIG=%(kubeconfig)s
export NAMESPACE=rajjoshi-dev
cd %(workspace)s/guides/pd-disaggregation
just benchmark 8 100 24000 512 2>&1 | tee "$OUTDIR/benchmark-isl24000-run1.txt"
```

Collect logs:
```bash
kubectl -n rajjoshi-dev logs -l llm-d.ai/role=decode -c vllm --tail=20000 > "$OUTDIR/decode-isl24000-run1.log" 2>&1
kubectl -n rajjoshi-dev logs -l llm-d.ai/role=prefill -c vllm --tail=20000 > "$OUTDIR/prefill-isl24000-run1.log" 2>&1
grep "KV Transfer metrics" "$OUTDIR/decode-isl24000-run1.log" > "$OUTDIR/kv-metrics-isl24000-run1.txt" 2>/dev/null
```

### Phase 2: Analyze and Investigate (if anomaly reproduces)

Extract ITL from both Run 1 benchmarks. Two scenarios:

**Scenario A: P99 ITL is normal (< 50ms)**
- Great! The anomaly was a one-off. Run each benchmark one more time (Run 2) to confirm consistency.
- Proceed to Phase 3.

**Scenario B: P99 ITL is anomalously high again (> 100ms)**
- Investigate systematically:

1. **Check for TTFT contamination**: vllm bench serve may include the first token's latency in ITL stats. Run:
   ```bash
   grep -E "(TTFT|ITL|TPOT)" "$OUTDIR/benchmark-isl4096-run1.txt"
   ```
   Compare Mean TTFT with P99 ITL. If P99 ITL ≈ Mean TTFT, the P99 outlier may just be
   the first token of some requests bleeding into the ITL distribution.

2. **Check cluster co-tenancy**: Are other workloads running on the same nodes?
   ```bash
   export KUBECONFIG=%(kubeconfig)s
   DECODE_NODE=$(kubectl -n rajjoshi-dev get pod -l llm-d.ai/role=decode -o jsonpath='{.items[0].spec.nodeName}')
   kubectl get pods --all-namespaces --field-selector spec.nodeName=$DECODE_NODE -o wide
   ```

3. **Check for GPU throttling or errors in decode logs**:
   ```bash
   grep -i -E "(error|warn|throttl|timeout|retry|stall)" "$OUTDIR/decode-isl4096-run1.log" | tail -30
   ```

4. **Run with different MC to isolate**:
   Try MC=1 (no concurrency) — if P99 is still high, it's not a concurrency issue:
   ```bash
   just benchmark 1 20 4096 512 2>&1 | tee "$OUTDIR/benchmark-isl4096-mc1.txt"
   ```

5. **Run a second time** (Run 2) to see if the anomaly is consistent or intermittent:
   ```bash
   just benchmark 8 100 4096 512 2>&1 | tee "$OUTDIR/benchmark-isl4096-run2.txt"
   ```

6. **Check if it's a vLLM streaming artifact**: Look at the raw per-request ITL distribution.
   The `--save-detailed` flag would capture per-request data, but we may not have it.
   Instead, check if the benchmark output mentions any failed/retried requests.

### Phase 3: Tear Down and Report

```bash
export KUBECONFIG=%(kubeconfig)s
cd %(workspace)s/guides/pd-disaggregation
helmfile -f helmfile.yaml.gotmpl destroy -e coreweave -n rajjoshi-dev
kubectl delete -f httproute.yaml -n rajjoshi-dev --ignore-not-found=true
kubectl -n rajjoshi-dev delete pod poker --ignore-not-found=true
```

### Final Summary
Print this EXACT format:

```
=== COREWEAVE TP4 ITL RERUN — INVESTIGATION REPORT ===

CONFIGURATION:
- Cluster: CoreWeave (UCX/IB)
- Model: RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic
- TP: 4, Replicas: 1P + 1D
- max-model-len: 32768
- Benchmark: MC=8, 100 requests, OSL=512
- Decode node: <node>
- Prefill node: <node>

RESULTS:
| Run | ISL   | Mean ITL (ms) | Median ITL (ms) | P99 ITL (ms) | Mean TTFT (ms) |
|-----|-------|---------------|-----------------|--------------|----------------|
(fill in all runs)

PREVIOUS RESULTS (for comparison):
| ISL=4096:  Mean=10.10, Median=8.04, P99=223.50
| ISL=24000: Mean=11.15, Median=10.27, P99=225.15

ANOMALY STATUS: [REPRODUCED / NOT REPRODUCED / INTERMITTENT]

INVESTIGATION FINDINGS:
- <detailed findings from all investigation steps performed>
- <root cause if identified>

OUTPUT LOCATION:
- <full path>

TEARDOWN STATUS:
- Confirm cleanup
```

## Important Notes
- Always set KUBECONFIG=%(kubeconfig)s before any kubectl/helmfile command.
- Run benchmarks ONE AT A TIME. Never overlap.
- Save ALL raw logs.
- Be thorough in investigation — the goal is to understand the root cause.
""" % {"kubeconfig": KUBECONFIG_CW, "workspace": WORKSPACE}

print("=" * 60)
print("CoreWeave TP4 ITL Rerun + Investigation — SDK Agent")
print("=" * 60)
print(f"API Key: {api_key[:10]}...")
print(f"Model: claude-opus-4-6")
print(f"Workspace: {WORKSPACE}")
print(f"KUBECONFIG: {KUBECONFIG_CW}")
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
