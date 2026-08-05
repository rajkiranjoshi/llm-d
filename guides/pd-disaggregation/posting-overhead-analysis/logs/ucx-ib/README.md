# P/D Disaggregation on CoreWeave: UCX/RDMA over InfiniBand

## Experiment Summary

**Goal:** Benchmark NIXL KV-cache transfer using UCX over RDMA InfiniBand (IB) on CoreWeave H200 nodes, comparing post time vs. xfer time against EFA/LIBFABRIC results from AWS EKS.

**Date:** 2026-08-05

## Cluster Configuration

| Property | Value |
|---|---|
| Cluster | CoreWeave Waldorf (`config.waldorf`) |
| GPU Nodes | `gd-8xh200ib-i128` (8x H200 per node, IB interconnect) |
| RDMA Resource | `rdma/ib: 1` (shared device — grants access to all IB devices) |
| KUBECONFIG | `/Users/rajjoshi/.kube/config.waldorf` |
| Namespace | `rajjoshi-dev` |
| Storage Class | `shared-vast` (NFS over VAST, RWX) |
| Gateway | Istio (`istio.io/gateway-controller`) |

## Deployment Configuration

| Property | Value |
|---|---|
| Model | `RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic` |
| Image | `ghcr.io/llm-d/llm-d-cuda:v0.8.1` |
| NIXL Backend | UCX (default, no explicit backend override) |
| Tensor Parallelism | 8 (both prefill and decode) |
| Replicas | 1P + 1D |
| Block Size | 128 |
| Max Model Len | 32768 |
| `IPC_LOCK` | Enabled (required for RDMA pinned memory) |
| Values File | `ms-pd/values_coreweave_rdma.yaml` |

### Node Placement

- Decode pod: `gf41fb2` (10.0.3.31)
- Prefill pod: `g12e022` (10.0.1.210)
- Cross-node RDMA transfer verified

## Benchmark Parameters

| Parameter | Value |
|---|---|
| Input Sequence Length (ISL) | 24000 tokens |
| Output Sequence Length (OSL) | 1 token |
| Number of Requests | 300 |
| Max Concurrency | 32 |
| Command | `just benchmark 32 300 24000 1` |

OSL=1 minimizes decode overhead so KV transfer time measurement is not confounded by decode-step latency. This matches the EKS benchmark setup.

## Results

### Serving Benchmark

| Metric | Value |
|---|---|
| Successful Requests | 300 |
| Failed Requests | 0 |
| Benchmark Duration | 283.56 s |
| Request Throughput | 1.06 req/s |
| Total Token Throughput | 25,391.82 tok/s |
| Mean TTFT | 28,700.81 ms |
| Median TTFT | 30,240.04 ms |
| P99 TTFT | 30,337.26 ms |
| Peak Concurrent Requests | 34 |

### KV Transfer Metrics (Steady-State, 28 samples, excluding warmup)

| Metric | Avg | P90 (avg) | Min | Max |
|---|---|---|---|---|
| Xfer time (ms) | **20.56** | 21.09 | 20.37 | 20.83 |
| Post time (ms) | **0.90** | 1.02 | 0.86 | 0.94 |
| Throughput (MB/s) | 45,726 | — | 45,118 | 46,144 |
| **Throughput (GB/s)** | **44.65** | — | 44.06 | 45.06 |
| Descriptors per transfer | 30,080 | — | — | — |
| Data per transfer | 940 MB | — | — | — |

### Warmup Sample (first 10s window)

| Metric | Value |
|---|---|
| Xfer time (ms) | 52.43 |
| Post time (ms) | 9.94 |
| Throughput (MB/s) | 17,928 |

## Key Findings

### 1. Post Time vs. Xfer Time — UCX vs. LIBFABRIC (apples-to-apples at ISL=24000)

**This was the primary goal of the experiment.** Both runs use identical workload parameters: ISL=24000, OSL=1, 300 requests, 30,080 descriptors / 940 MB per transfer.

| Metric | UCX/IB (CoreWeave H200) | LIBFABRIC/EFA (EKS p5.48xl) |
|---|---|---|
| Avg xfer time (ms) | **20.56** | 81.47 |
| Avg post time (ms) | **0.90** | 81.20 |
| Post/xfer ratio | **4.4%** | **99.7%** |
| Avg delta (xfer − post) (ms) | 19.66 | 0.27 |
| Throughput (GB/s) | **44.65** | 11.31 |
| Descriptors per transfer | 30,080 | 30,080 |
| Data per transfer | 940 MB | 940 MB |

#### EFA/LIBFABRIC Steady-State Detail (24 samples, excluding warmup)

| Metric | Avg | P90 (avg) | Min | Max |
|---|---|---|---|---|
| Xfer time (ms) | 81.47 | 99.46 | 77.24 | 88.53 |
| Post time (ms) | 81.20 | 99.20 | 76.97 | 88.27 |
| Throughput (GB/s) | 11.31 | — | 10.37 | 11.89 |

#### Interpretation

With UCX/IB, **post time is only 4.4% of xfer time** — the 0.90ms post represents the time to issue RDMA write requests to the NIC, and the remaining 19.66ms is the actual data transfer completing asynchronously. UCX posts descriptors in bulk and returns immediately.

With LIBFABRIC/EFA, **post time is 99.7% of xfer time** — the 0.27ms delta is essentially zero. This means LIBFABRIC's `fi_write` loop is the bottleneck: each descriptor is posted synchronously, and the loop doesn't return until all 30,080 descriptors have been submitted. The "transfer" as measured by NIXL is entirely dominated by the posting phase.

This confirms that:
- LIBFABRIC's posting throughput on EFA is ~11.6 MB/descriptor/s (940 MB in 81ms)
- UCX's posting throughput on IB is ~1,044 MB/descriptor/s (940 MB in 0.9ms post)
- The actual RDMA wire transfer on UCX/IB completes in ~20ms for 940 MB = **47 GB/s** effective wire speed
- EFA's actual RDMA wire speed cannot be isolated because posting dominates

### 2. Throughput

UCX/IB achieved **44.65 GB/s** average throughput (end-to-end including post). This is **3.9x** the LIBFABRIC/EFA throughput of 11.31 GB/s on the same 940 MB payload, primarily because UCX posting is non-blocking.

### 3. Warmup Phase

The first sample shows 52.43ms xfer time (vs. 20.56ms steady-state). This is the UCX connection establishment and memory registration overhead — a one-time cost on the first transfer.

### 4. Consistency

Xfer time variance is extremely low in steady state: 20.37–20.83ms range across 28 samples (< 2.3% variation).

## Files

| File | Description |
|---|---|
| `decode-pod.log` | Full decode pod vLLM logs |
| `prefill-pod.log` | Full prefill pod vLLM logs |
| `benchmark-output.log` | vllm bench serve output |
| `kv-transfer-metrics-raw.txt` | Extracted KV Transfer metrics lines |

## Reproducing

```bash
# Set KUBECONFIG
export KUBECONFIG=/Users/rajjoshi/.kube/config.waldorf

# Deploy from guides/pd-disaggregation/
helmfile -f helmfile.yaml.gotmpl apply -e coreweave -n rajjoshi-dev
kubectl apply -f httproute.yaml -n rajjoshi-dev

# Wait for pods
kubectl -n rajjoshi-dev wait --for=condition=Ready pod -l llm-d.ai/role=decode --timeout=1200s
kubectl -n rajjoshi-dev wait --for=condition=Ready pod -l llm-d.ai/role=prefill --timeout=1200s

# Deploy poker and run benchmark
kubectl apply -f ../../poker/poker.yaml -n rajjoshi-dev
# From poker pod:
vllm bench serve --base-url <GATEWAY_URL> --model <MODEL> \
  --dataset-name random --random-input-len 24000 --random-output-len 1 \
  --max-concurrency 32 --request-rate 4096 --num-prompts 300 --ignore-eos
```

## Teardown

```bash
helmfile -f helmfile.yaml.gotmpl destroy -e coreweave -n rajjoshi-dev
kubectl delete -f httproute.yaml -n rajjoshi-dev --ignore-not-found
```
