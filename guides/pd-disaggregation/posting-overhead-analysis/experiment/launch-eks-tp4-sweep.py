#!/usr/bin/env python3
"""
Launch a Cursor SDK agent to run the ISL sweep experiment on EKS with TP4.
Run this inside a tmux session so it persists when the laptop disconnects.

Usage:
    tmux attach -t cursor-agent-eks
    python3 launch-eks-tp4-sweep.py
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

PROMPT = f"""
You are running an ISL sweep experiment for P/D disaggregated inference on EKS with TP4 configuration.
This is a REAL deployment on a REAL cluster. Execute commands carefully and monitor output.

## Environment
- KUBECONFIG: {KUBECONFIG_EKS}
- Namespace: raj-dev
- Workspace: {WORKSPACE}
- Working directory for just/helmfile: {WORKSPACE}/guides/pd-disaggregation

## What Has Already Been Done
- The EKS values file exists at: guides/pd-disaggregation/ms-pd/values_eks_rdma.yaml
  (currently TP=8, EFA=32, --max-model-len=32768, Llama-3.3-70B-Instruct-FP8-dynamic, LIBFABRIC backend)
- The HF token secret (llm-d-hf-token) already exists in namespace raj-dev.
- Namespace raj-dev already exists.
- helm, helmfile, just, kubectl are all installed and available.

## Key TP4 Changes for EKS
- Tensor parallelism: 8 → 4
- EFA NICs: 4 × TP = 4 × 4 = 16 (was 32 for TP8)
- The Justfile's deploy-helm recipe handles TP and EFA overrides via --set flags automatically.
- --max-model-len stays at 32768 in the values file. Try this first — if vLLM can't start with TP4 + 32k, reduce it.

## Your Task — Execute These Steps in Order

### Step 1: Deploy the P/D Stack with TP4
Run from the guides/pd-disaggregation directory. Use the Justfile with env overrides:

```bash
export KUBECONFIG={KUBECONFIG_EKS}
export NAMESPACE=raj-dev
export HELMFILE_ENV=eks_rdma
export PREFILL_TP=4
export DECODE_TP=4
export PREFILL_REPLICAS=1
export DECODE_REPLICAS=1
cd {WORKSPACE}/guides/pd-disaggregation
just deploy
```

This will compute EFA NICs = 4 × 4 = 16 per pod and pass the overrides via helmfile --set.

### Step 2: Wait for Pods to Be Ready
Wait for prefill, decode, and EPP pods to become Ready. This can take up to 20 minutes
(model download + loading). Monitor with:

```bash
export KUBECONFIG={KUBECONFIG_EKS}
kubectl -n raj-dev get pods -o wide -w
```

Check every 5 minutes (not more frequently — conserve tokens while waiting). If pods crash or fail:
- Check logs: `kubectl -n raj-dev logs -l llm-d.ai/role=decode -c vllm --tail=200`
- If you see OOM or "max_model_len" errors, the --max-model-len=32768 is too large for TP4.
  In that case:
  1. Edit guides/pd-disaggregation/ms-pd/values_eks_rdma.yaml
  2. Change --max-model-len from "32768" to "24576" (try this first) or "16384" (fallback)
  3. Re-run: `just deploy` (with the same env vars from Step 1)
  4. Wait for pods again
  5. NOTE: If max-model-len drops below 24000, remove 24000 from the ISL sweep list
  6. IMPORTANT: After the experiment, restore --max-model-len back to "32768" in the values file.

### Step 3: Deploy Poker Pod
```bash
export KUBECONFIG={KUBECONFIG_EKS}
kubectl apply -f {WORKSPACE}/poker/poker.yaml -n raj-dev
kubectl -n raj-dev wait --for=condition=Ready pod/poker --timeout=120s
```

### Step 4: Run the ISL Sweep
Set these environment variables first:

```bash
export KUBECONFIG={KUBECONFIG_EKS}
export NAMESPACE=raj-dev
```

Then run:
```bash
cd {WORKSPACE}/guides/pd-disaggregation
bash posting-overhead-analysis/experiment/run-isl-sweep.sh libfabric-efa 300 32
```

This will:
- Loop over ISLs: 1024, 2048, 4096, 8192, 16384, 24000
- For each ISL: run `just benchmark`, collect decode/prefill logs, extract KV metrics
- Output goes to: posting-overhead-analysis/benchmark-logs/isl-sweep-libfabric-efa-<timestamp>/
- OSL is hardcoded to 1 (posting overhead measurement)

**IMPORTANT**: If --max-model-len was reduced below 24000 in Step 2, you MUST edit
run-isl-sweep.sh to remove ISL values that exceed the max-model-len BEFORE running it.
If you edit run-isl-sweep.sh, restore it after the sweep.

### Step 5: Verify and Report Results
After the sweep completes:
1. Read the summary.md from the output directory
2. Read the results.csv
3. Print a summary of the results including:
   - Which ISL values were tested
   - Average post time (ms) and average xfer time (ms) for each ISL
   - Throughput (GB/s) for each ISL
   - Whether any ISL points failed
   - The max-model-len that was used
   - Node placement (which nodes got prefill vs decode)
4. List all output files with their sizes

### Step 6: Save Node and Pod Info
Before tearing down, capture:
```bash
export KUBECONFIG={KUBECONFIG_EKS}
kubectl -n raj-dev get pods -o wide > <output_dir>/pod-placement.txt
kubectl get nodes -o wide > <output_dir>/node-info.txt
```

### Step 7: Tear Down
After the sweep is complete and all logs/results are saved:
```bash
export KUBECONFIG={KUBECONFIG_EKS}
export NAMESPACE=raj-dev
export HELMFILE_ENV=eks_rdma
cd {WORKSPACE}/guides/pd-disaggregation
helmfile -f helmfile.yaml.gotmpl destroy -e eks_rdma -n raj-dev
kubectl delete -f httproute.yaml -n raj-dev --ignore-not-found=true
kubectl -n raj-dev delete pod poker --ignore-not-found=true
```

If you edited values_eks_rdma.yaml (e.g. changed max-model-len), restore it to the original values.

### Step 8: Final Summary
As your LAST output, print a concise structured summary with these sections:

```
=== EKS TP4 ISL SWEEP — FINAL REPORT ===

CONFIGURATION:
- Cluster: EKS (LIBFABRIC/EFA)
- Model: <model name>
- TP: 4, EFA NICs: 16, Replicas: 1P + 1D
- max-model-len: <value used>
- Prefill node: <node name>
- Decode node: <node name>

RESULTS TABLE:
| ISL | Post (ms) | Xfer (ms) | Post/Xfer % | Throughput (GB/s) |
|-----|-----------|-----------|-------------|-------------------|
(fill in for each ISL)

TROUBLESHOOTING LOG:
- List every issue encountered and how it was resolved
- If max-model-len was adjusted, state original → final value and why
- If any ISL points were skipped, state which and why
- If any retries were needed, describe what failed and the fix
- If values_eks_rdma.yaml was modified, confirm it was restored

OUTPUT LOCATION:
- <full path to results directory>
- List key files and their sizes

TEARDOWN STATUS:
- Confirm all resources were deleted
```

## Important Notes
- Always set KUBECONFIG={KUBECONFIG_EKS} before any kubectl/helmfile command.
- The EKS cluster uses LIBFABRIC/EFA backend (not UCX). The sweep label is "libfabric-efa".
- If any step fails, diagnose the issue, fix it, and retry. Log everything you do.
- This is a TP4 experiment (4 GPUs per pod). The previous TP8 experiment used 8 GPUs per pod.
- EFA NICs = 4 × TP. For TP4 that's 16 EFA NICs per pod.
- The experiment measures NIXL KV cache transfer posting overhead, so OSL=1 is critical.
"""

print("=" * 60)
print("EKS TP4 ISL Sweep — SDK Agent Launcher")
print("=" * 60)
print(f"API Key: {api_key[:10]}...")
print(f"Model: claude-opus-4-6 (thinking=true, effort=high)")
print(f"Workspace: {WORKSPACE}")
print(f"KUBECONFIG: {KUBECONFIG_EKS}")
print()
print("Launching agent... This will take a while (deploy + sweep).")
print("Monitor progress in this terminal.")
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
