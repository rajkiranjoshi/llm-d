# Thread Pool Evaluation: NIXL v1.2.0 Baseline (TP4)

This report captures the **baseline** performance of NIXL v1.2.0 with TP=4 on both backends (UCX/IB and LIBFABRIC/EFA). These results will be compared against NIXL ≥ v1.3.2 with `NIXL_LIBFABRIC_NUM_THREADS=4` (posting thread pool, [Solution A](libfabric-posting-analysis.md#solution-a-posting-thread-pool-nixl--v132)) to measure the impact of parallelized descriptor posting on both posting overhead and ITL.

**All results below are with NIXL v1.2.0 (no thread pool).**

---



## Experiment Configuration

| Property      | UCX / IB (CoreWeave)                | LIBFABRIC / EFA (EKS)              |
| ------------- | ----------------------------------- | ---------------------------------- |
| Cluster       | CoreWeave H200 IB                   | AWS EKS p5.48xlarge                |
| GPU           | 8× H200 per node                   | 8× H100 per node                  |
| NIC           | InfiniBand (shared device)          | 32× EFA NICs                      |
| RDMA resource | `rdma/ib: 1`                        | `vpc.amazonaws.com/efa: 16`        |
| Image         | `ghcr.io/llm-d/llm-d-cuda:v0.8.1`  | `ghcr.io/llm-d/llm-d-aws:v0.8.1`  |
| vLLM          | v0.23.0                             | v0.23.0                            |
| NIXL          | **v1.2.0**                          | **v1.2.0**                         |
| Model         | Llama-3.3-70B-Instruct-FP8-dynamic  | Llama-3.3-70B-Instruct-FP8-dynamic |
| **TP**        | **4**                               | **4**                              |
| max-model-len | 32768                               | 32768                              |
| Topology      | 1P + 1D cross-node                  | 1P + 1D cross-node                 |
| Block size    | 128                                 | 128                                |

---



## Set 1: ISL Sweep — Posting Overhead (OSL=1)

MC=32, 300 requests, OSL=1, `--block-size 128`.

### UCX / IB (CoreWeave)

| ISL    | Descs  | MB/xfer | Post (ms) | Xfer (ms) | Post/Xfer % | Throughput (GB/s) | Samples |
| ------ | ------ | ------- | --------- | --------- | ----------- | ----------------- | ------- |
| 1,024  | 1,277  | 80      | 0.19      | 10.97     | 1.7%        | 7.11              | 6       |
| 2,048  | 2,548  | 159     | 0.26      | 12.40     | 2.1%        | 12.55             | 8       |
| 4,096  | 5,100  | 319     | 0.34      | 13.93     | 2.4%        | 22.35             | 12      |
| 8,192  | 10,240 | 640     | 0.67      | 14.29     | 4.7%        | 43.75             | 13      |
| 16,384 | 20,480 | 1,280   | 0.91      | 27.64     | 3.3%        | 45.22             | 27      |
| 24,000 | 30,080 | 1,880   | 1.15      | 40.41     | 2.9%        | 45.44             | 42      |

Run: `benchmark-logs/isl-sweep-ucx-ib-20260806-222106/`


### LIBFABRIC / EFA (EKS)

| ISL    | Descs  | MB/xfer | Post (ms) | Xfer (ms) | Post/Xfer % | Throughput (GB/s) | Samples |
| ------ | ------ | ------- | --------- | --------- | ----------- | ----------------- | ------- |
| 1,024  | 1,271  | 79      | 3.65      | 12.31     | 29.6%       | 6.32              | 7       |
| 2,048  | 2,556  | 160     | 7.43      | 17.37     | 42.8%       | 9.01              | 3       |
| 4,096  | 5,120  | 320     | 24.85     | 92.28     | 26.9%       | 11.89             | 7       |
| 8,192  | 10,240 | 640     | 28.49     | 28.74     | 99.1%       | 21.75             | 13      |
| 16,384 | 20,480 | 1,280   | 54.38     | 54.66     | 99.5%       | 22.91             | 28      |
| 24,000 | 30,080 | 1,880   | 76.55     | 76.85     | 99.6%       | 23.89             | 22      |

ISL=1024 from rerun (`benchmark-logs/isl-rerun-libfabric-efa-20260807-040900/`). ISL=24000 from rerun. Others from original sweep (`benchmark-logs/isl-sweep-libfabric-efa-20260806-204846/`), recomputed to exclude contaminated lines from prior ISL runs (see [Data Processing Fix](#data-processing-fix)).

> **Note:** MB per transfer is 2× the TP=8 value (e.g. 1,880 MB vs 940 MB at ISL=24K) because TP=4 gives each GPU 2 KV heads (vs 1 at TP=8), doubling the per-transfer data. Descriptor count is the same as TP=8: `ceil(ISL/128) × 80 layers × 2 (K+V)` — independent of TP.


### Side-by-Side: Post Time and Throughput

| ISL    | UCX Post (ms) | LF Post (ms) | **Post Gap** | UCX TP (GB/s) | LF TP (GB/s) | **TP Ratio** |
| ------ | ------------- | ------------ | ------------ | ------------- | ------------ | ------------ |
| 1,024  | 0.19          | 3.65         | 19×          | 7.11          | 6.32         | 1.1×         |
| 2,048  | 0.26          | 7.43         | 29×          | 12.55         | 9.01         | 1.4×         |
| 4,096  | 0.34          | 24.85        | 73×          | 22.35         | 11.89        | 1.9×         |
| 8,192  | 0.67          | 28.49        | 43×          | 43.75         | 21.75        | 2.0×         |
| 16,384 | 0.91          | 54.38        | 60×          | 45.22         | 22.91        | 2.0×         |
| 24,000 | 1.15          | 76.55        | 67×          | 45.44         | 23.89        | 1.9×         |

At TP4, the posting gap is **19–73×** and the throughput ratio is **1.1–2.0×**. Both backends show the same descriptor count (30,080 at ISL=24K) but TP4 transfers 2× the data per descriptor (2 KV heads/GPU). UCX post time stays under 1.2 ms. LIBFABRIC post time (76.55 ms at ISL=24K) is slightly higher than TP8 (73.2 ms) — same number of descriptors × ~2.5 μs per-descriptor cost, with marginal overhead from larger RDMA reads.

---



## Set 2: ITL Impact (OSL=512)

MC=8, 100 requests, OSL=512.

### UCX / IB (CoreWeave)

| ISL    | Mean ITL (ms) | Median ITL (ms) | P99 ITL (ms) | Avg Post (ms) | Avg Xfer (ms) |
| ------ | ------------- | --------------- | ------------ | -------------- | -------------- |
| 4,096  | 9.77          | 9.77            | 14.71        | 0.44           | 10.05          |
| 24,000 | 10.87         | 10.90           | 13.96        | 0.78           | 32.03          |

Run: `benchmark-logs/itl-ucx-ib-tp4-20260807-131322/`


### LIBFABRIC / EFA (EKS)

| ISL    | Mean ITL (ms) | Median ITL (ms) | P99 ITL (ms) | Avg Post (ms) | Avg Xfer (ms) |
| ------ | ------------- | --------------- | ------------ | -------------- | -------------- |
| 4,096  | 11.85         | 11.81           | 16.33        | 14.02          | 16.49          |
| 24,000 | 15.21         | 14.74           | 40.95        | 52.91          | 54.12          |

Run: `benchmark-logs/itl-libfabric-efa-tp4-20260807-042527/`


### Side-by-Side: ITL Comparison

| ISL    | UCX Mean ITL | LF Mean ITL | **Mean Gap** | UCX P99 ITL  | LF P99 ITL   | **P99 Gap** |
| ------ | ------------ | ----------- | ------------ | ------------ | ------------ | ----------- |
| 4,096  | 9.77 ms      | 11.85 ms    | +2.08 ms     | 14.71 ms     | 16.33 ms     | UCX better  |
| 24,000 | 10.87 ms     | 15.21 ms    | +4.34 ms     | 13.96 ms     | 40.95 ms     | UCX better  |

**Observation:** UCX/IB consistently outperforms LIBFABRIC/EFA on both mean and P99 ITL. The mean ITL gap (+21% at ISL=4K, +40% at ISL=24K) reflects LIBFABRIC's posting overhead blocking `model.forward()`. The P99 gap is dramatic at ISL=24K: **14.0 ms (UCX) vs. 41.0 ms (LIBFABRIC)** — a **2.9× penalty**. This is consistent with the TP8 results (14.0 vs 84.2 ms) and directly attributable to LIBFABRIC's synchronous ~77 ms posting loop stalling the decode batch.

---



## Comparison: TP4 vs TP8 (NIXL v1.2.0)

### Posting Overhead (OSL=1)

| ISL    | UCX TP8 Post | UCX TP4 Post | LF TP8 Post | LF TP4 Post |
| ------ | ------------ | ------------ | ----------- | ----------- |
| 1,024  | 0.20 ms      | 0.19 ms      | 3.3 ms      | 3.65 ms     |
| 4,096  | 0.31 ms      | 0.34 ms      | 11.0 ms     | 24.85 ms    |
| 8,192  | 0.56 ms      | 0.67 ms      | 25.4 ms     | 28.49 ms    |
| 16,384 | 0.77 ms      | 0.91 ms      | 47.3 ms     | 54.38 ms    |
| 24,000 | 0.90 ms      | 1.15 ms      | 73.2 ms     | 76.55 ms    |

Descriptor count is the same at TP=4 and TP=8 (e.g., 30,080 at ISL=24K): `ceil(ISL/128) × 80 layers × 2 (K+V)` — independent of TP. Each descriptor is 2× larger at TP=4 (64 KB vs 32 KB, because each GPU handles 2 KV heads instead of 1), so total MB/transfer doubles (1,880 MB vs 940 MB at ISL=24K).

UCX posting increases slightly at TP=4 (0.90 → 1.15 ms at ISL=24K), likely from the 2× larger RDMA reads per descriptor causing marginal overhead in `ucp_get_nbx`. LIBFABRIC posting increases similarly (73.2 → 76.55 ms), consistent with the same 30,080 descriptors and ~2.5 μs per-descriptor cost — the larger RDMA read size adds only a small overhead to the MMIO-bound posting loop.

### ITL (OSL=512)

| ISL    | UCX TP8 Mean/P99 | UCX TP4 Mean/P99  | LF TP8 Mean/P99   | LF TP4 Mean/P99   |
| ------ | ----------------- | ----------------- | ----------------- | ------------------ |
| 4,096  | 7.77 / 11.81 ms   | 9.77 / 14.71 ms   | 8.82 / 16.97 ms   | 11.85 / 16.33 ms   |
| 24,000 | 8.57 / 13.96 ms   | 10.87 / 13.96 ms  | 11.76 / 84.18 ms  | 15.21 / 40.95 ms   |

TP4 increases mean ITL on both backends (~25–30% higher) due to reduced compute parallelism (half the GPUs for decode). UCX P99 remains stable across TP configurations (~12–15 ms), confirming that posting overhead has negligible impact on tail latency when posting is sub-ms. LIBFABRIC P99 **improved** at TP4 vs TP8 (84 ms → 41 ms at ISL=24K), despite posting time being nearly identical (~77 ms vs ~73 ms). This improvement likely reflects reduced batch interference or different scheduling dynamics at TP4, not posting-time reduction.

---



## What Comes Next

Bump to **NIXL ≥ v1.3.2** and set `NIXL_LIBFABRIC_NUM_THREADS=4` (posting thread pool). Re-run all 4 sets:

1. ISL sweep (OSL=1) on UCX/IB (CoreWeave) — control, should be unchanged
2. ISL sweep (OSL=1) on LIBFABRIC/EFA (EKS) — expect ~4× reduction in post time
3. ITL (OSL=512) on UCX/IB (CoreWeave) — control
4. ITL (OSL=512) on LIBFABRIC/EFA (EKS) — expect reduced mean ITL and P99

The thread pool splits the descriptor posting loop across 4 threads, each posting to a different EFA NIC. With 4 EFA NICs per GPU at TP4, this should achieve near-ideal parallelism for the MMIO-bound posting loop, reducing the ~77 ms post time at ISL=24K to ~19 ms.

---



## Data Processing Fix

The original `run-isl-sweep.sh` script had a bug that contaminated KV transfer metrics across ISL runs. The script uses `kubectl logs --tail=10000` to capture decode pod logs after each ISL benchmark. Since the decode pod runs continuously through all ISL values, each subsequent log capture includes metric lines from **all previous ISL runs**.

For example, when running ISL=24000 (the 6th point):
- `kv-metrics-isl24000.txt` contained **114 lines** — but only the last **43** were from ISL=24000
- The first 71 lines came from ISL=1024 through ISL=16384
- Averaging all 114 lines produced descriptor counts of ~18,393 instead of the actual 30,080

This made it appear that TP=4 had fewer descriptors than TP=8, when in fact the descriptor count is identical: `ceil(ISL/128) × 80 × 2`. The tables in this report use corrected values computed by extracting only the new lines added by each ISL run.

**Fix:** The sweep script should record the current log line count before each benchmark and use `--since-time` or `tail -n +<offset>` to capture only new log lines.

---



## Raw Data Locations

| Set | Backend | Logs Directory |
| --- | ------- | -------------- |
| ISL Sweep (OSL=1) | UCX/IB | `benchmark-logs/isl-sweep-ucx-ib-20260806-222106/` |
| ISL Sweep (OSL=1) | LIBFABRIC/EFA | `benchmark-logs/isl-sweep-libfabric-efa-20260806-204846/` (ISL 2K–16K) + `benchmark-logs/isl-rerun-libfabric-efa-20260807-040900/` (ISL 1K, 24K) |
| ITL (OSL=512) | UCX/IB | `benchmark-logs/itl-ucx-ib-tp4-20260807-131322/` |
| ITL (OSL=512) | LIBFABRIC/EFA | `benchmark-logs/itl-libfabric-efa-tp4-20260807-042527/` |

All paths relative to `guides/pd-disaggregation/`.
