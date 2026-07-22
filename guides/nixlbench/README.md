# nixlbench on EKS (EFA) with `llm-d-aws`

One-shot guide to run [nixlbench](https://github.com/ai-dynamo/nixl/tree/v1.0.0/benchmark/nixlbench) between two pods on AWS EKS using `ghcr.io/llm-d/llm-d-aws:v0.8.1`.

The image already contains NIXL (with LIBFABRIC linked against EFA libfabric) and UCX. It does **not** ship the `nixlbench` binary or a NIXL **UCCL** plugin — install scripts build those against the image’s NIXL runtime (without replacing the wheel).

## Topology

| Component | Spec |
|-----------|------|
| Namespace | `raj-nixlbench` |
| etcd | 1 small Deployment + ClusterIP `:2379` |
| `nixlbench-a` / `nixlbench-b` | `sleep infinity`, 4× GPU + 16× `vpc.amazonaws.com/efa`, hostname anti-affinity |
| Image | `ghcr.io/llm-d/llm-d-aws:v0.8.1` |
| nixlbench source | NIXL git tag `v1.2.0` (matches `nixl==1.2.0` wheel in `llm-d-aws:v0.8.1`) |

## Prerequisites

1. EFA device plugin installed; nodes advertise `vpc.amazonaws.com/efa`.
2. Enough free GPUs: **4 free on each of two nodes** (16 EFA free each).

```bash
# use the EFA resource name (default sriov-rdma-vf is wrong on EKS)
just check-gpu-rdma-resources vpc.amazonaws.com/efa
```

Free capacity on any node that is short of GPUs before applying the pods.

## 1. Deploy

```bash
cd guides/nixlbench
kubectl apply -f manifests/namespace.yaml
kubectl apply -f manifests/etcd.yaml
kubectl apply -f manifests/nixlbench-pods.yaml

kubectl -n raj-nixlbench rollout status deploy/etcd --timeout=120s
kubectl -n raj-nixlbench wait --for=condition=Ready pod/nixlbench-a pod/nixlbench-b --timeout=300s
kubectl -n raj-nixlbench get pods -o wide
# expect nixlbench-a and nixlbench-b Running on different nodes
```

## 2. Copy scripts into both pods

```bash
for p in nixlbench-a nixlbench-b; do
  kubectl -n raj-nixlbench exec "$p" -- mkdir -p /tmp/nixlbench-scripts
  for s in install-nixlbench.sh install-uccl-p2p.sh check-nixlbench.sh run-bench.sh run-bench-sg.sh; do
    kubectl -n raj-nixlbench cp "scripts/$s" "$p:/tmp/nixlbench-scripts/$s"
  done
  kubectl -n raj-nixlbench exec "$p" -- chmod +x /tmp/nixlbench-scripts/*.sh
done
```

## 3. Install nixlbench (once per pod)

Builds `nixlbench` from NIXL `v1.2.0`, using headers from that source tree and dynamically linking the image’s wheel libs under `/opt/vllm` (does **not** rebuild NIXL/libfabric).

```bash
# can run in parallel; first run may take several minutes (deps + compile)
kubectl -n raj-nixlbench exec nixlbench-a -- bash /tmp/nixlbench-scripts/install-nixlbench.sh
kubectl -n raj-nixlbench exec nixlbench-b -- bash /tmp/nixlbench-scripts/install-nixlbench.sh
```

Override the git pin if needed: `NIXL_GIT_REF=v1.2.0`.

## 4. Check installation

```bash
kubectl -n raj-nixlbench exec nixlbench-a -- bash /tmp/nixlbench-scripts/check-nixlbench.sh
kubectl -n raj-nixlbench exec nixlbench-b -- bash /tmp/nixlbench-scripts/check-nixlbench.sh
```

Expect ~16 EFA `fi_info` providers and 4 GPUs per pod. Script exits non-zero on failure.

Optional: `EXPECT_EFA_MIN=16` to require a full EFA count.

## 4b. Install UCCL P2P + NIXL UCCL plugin (optional, for `BACKEND=UCCL`)

In-pod only: builds [UCCL P2P](https://github.com/uccl-project/uccl/tree/v0.1.1/p2p) `v0.1.1` (`libuccl_p2p`), then clones NIXL `v1.2.0` **source** to compile **`libplugin_UCCL.so` only** (does **not** replace the image NIXL wheel). EFA is selected at runtime via `UCCL_P2P_TRANSPORT=efa`.

```bash
# after install-nixlbench.sh; can run in parallel on both pods (several minutes)
kubectl -n raj-nixlbench exec nixlbench-a -- bash /tmp/nixlbench-scripts/install-uccl-p2p.sh
kubectl -n raj-nixlbench exec nixlbench-b -- bash /tmp/nixlbench-scripts/install-uccl-p2p.sh

kubectl -n raj-nixlbench exec nixlbench-a -- \
  env CHECK_UCCL=1 bash /tmp/nixlbench-scripts/check-nixlbench.sh
kubectl -n raj-nixlbench exec nixlbench-b -- \
  env CHECK_UCCL=1 bash /tmp/nixlbench-scripts/check-nixlbench.sh
```

Artifacts: `/opt/uccl-p2p/lib/libuccl_p2p.so`, `/opt/uccl-p2p/nixl-plugins/` (merged wheel plugins + UCCL), `/usr/local/nixlbench/uccl-env.sh`.

## 5. Run experiments (SG only)

Use **SG** (`run-bench-sg.sh`): **N processes × 1 GPU** per pod — one NIXL agent per GPU. That matches vLLM **TP** and **DP**, where each GPU worker creates its own NIXL instance (and each uses PCIe-aligned EFA NICs with LIBFABRIC/UCCL).

Start **both pods within ~60s** (etcd barrier). Start the **initiator** pod first so etcd ranks 0..N-1 land there, then the target. Prefer two terminals.

`run-bench.sh` (single-process / MG) is kept for debugging only; results below are **SG only**.

### LIBFABRIC — EFA

```bash
# terminal 1 — initiator
kubectl -n raj-nixlbench exec -it nixlbench-a -- \
  env BACKEND=LIBFABRIC ROLE=initiator NUM_DEV=4 BENCH_GROUP=libfabric-sg \
  bash /tmp/nixlbench-scripts/run-bench-sg.sh

# terminal 2 — target (immediately after)
kubectl -n raj-nixlbench exec -it nixlbench-b -- \
  env BACKEND=LIBFABRIC ROLE=target NUM_DEV=4 BENCH_GROUP=libfabric-sg \
  bash /tmp/nixlbench-scripts/run-bench-sg.sh
```

Rank-0 BW table is printed at the end of the initiator run (also under `/tmp/nixlbench-sg-logs/`).

Notes:
- Leave `--device_list=all` (script default). A numeric list makes nixlbench index `devices[global_rank]` and can abort on target ranks.
- Each worker pins VRAM with `cudaSetDevice(local_rank)`; memory registers on **4 PCIe-aligned EFA rails** per GPU (`max_rails=4`).

### UCX (TCP on this image — not EFA)

```bash
kubectl -n raj-nixlbench exec -it nixlbench-a -- \
  env BACKEND=UCX ROLE=initiator NUM_DEV=4 BENCH_GROUP=ucx-sg \
  bash /tmp/nixlbench-scripts/run-bench-sg.sh
# …ROLE=target on nixlbench-b
```

On `llm-d-aws:v0.8.1`, the NIXL wheel’s embedded UCX only exposes `tcp/sm/cuda_*` (no `efa`/`srd`). Use **LIBFABRIC** or **UCCL** for EFA RDMA.

### UCCL — EFA (after §4b)

Requires `install-uccl-p2p.sh`. Run scripts source `uccl-env.sh` (`UCCL_P2P_TRANSPORT=efa`, `UCCL_RCMODE=1` for READ, merged `NIXL_PLUGIN_DIR`).

```bash
kubectl -n raj-nixlbench exec -it nixlbench-a -- \
  env BACKEND=UCCL ROLE=initiator NUM_DEV=4 BENCH_GROUP=uccl-sg \
  bash /tmp/nixlbench-scripts/run-bench-sg.sh
kubectl -n raj-nixlbench exec -it nixlbench-b -- \
  env BACKEND=UCCL ROLE=target NUM_DEV=4 BENCH_GROUP=uccl-sg \
  bash /tmp/nixlbench-scripts/run-bench-sg.sh
```

Notes:
- Leave `UCCL_P2P_RDMA_DEV` unset for PCIe-affinity auto NIC pick; set only to override.
- Confirm logs show `Selected backend: UCCL` and BW is not TCP-scale (~0.3 GB/s).

### Reference results (VRAM READ, SG, 4↔4 GPU)

One NIXL agent per GPU (vLLM TP/DP-shaped). Aggregate ≈ sum of 4 pairwise streams.

**Throughput + node CPU** (EKS p5.48xlarge). Re-run with [`scripts/run-sg-cpu-suite-host.sh`](scripts/run-sg-cpu-suite-host.sh) (needs Prom port-forward to `:9090`).

CPU metric = **whole-node** busy% from Prometheus node-exporter:

`100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle",instance="<node-ip>:9100"}[1m])))`

That is **not** pod/cgroup CPU and **not** normalized to the 4/8 GPUs or 16/32 EFA NICs this bench uses — it is busy% across **all** CPUs on the p5.48xlarge.

CPU columns are **initiator** vs **target** node (not “initial” / no-load). The idle baseline row is measured with no nixlbench running.

| Backend | Transport | Msg size | Per-stream (GB/s) | Aggregate (GB/s) | CPU initiator avg/max % | CPU target avg/max % |
|---------|-----------|----------|------------------:|-----------------:|------------------------:|---------------------:|
| *(idle baseline)* | — | — | — | — | 0.13 / 0.13 | 0.46 / 0.46 |
| LIBFABRIC | EFA | 1 MiB | 13.2 | 53.7 | 0.29 / 0.46 | 0.47 / 0.51 |
| LIBFABRIC | EFA | 4 MiB | 27.7 | 110.5 | 0.30 / 0.41 | 0.44 / 0.59 |
| LIBFABRIC | EFA | 16 MiB | 36.4 | 145.9 | 0.29 / 0.37 | 0.43 / 0.58 |
| LIBFABRIC | EFA | 64 MiB | 43.7 | 176.2 | 0.30 / 0.44 | 0.46 / 0.56 |
| UCCL | EFA | 1 MiB | 9.8 | 38.8 | 2.12 / 3.92 | 2.10 / 4.16 |
| UCCL | EFA | 4 MiB | 25.1 | 102.6 | 2.10 / 5.02 | 2.07 / 5.03 |
| UCCL | EFA | 16 MiB | 39.6 | 159.1 | 2.10 / 5.67 | 2.11 / 5.43 |
| UCCL | EFA | 64 MiB | 43.6 | 174.8 | 2.01 / 5.23 | 2.11 / 5.37 |
| UCX | TCP | 1–64 MiB | ~0.32–0.33 | ~1.3 | — | — |

Takeaway: at large messages LIBFABRIC and UCCL reach similar aggregate BW (~175 GB/s), but UCCL keeps ~2% avg / ~5% peak **node** CPU on **both** sides (software reliability/CC on UD), while LIBFABRIC stays near idle (~0.3%) with device RDMA READ.

**CPU vs NUM_DEV** (fixed 64 MiB READ; `NUM_DEV` = NIXL agents / GPUs per side; sweep via [`scripts/run-sg-ndev-cpu-suite-host.sh`](scripts/run-sg-ndev-cpu-suite-host.sh); skipped `NUM_DEV=3` — nixlbench default 8 GiB buffer is not divisible by 3):

| Backend | NUM_DEV | Per-stream (GB/s) | Aggregate (GB/s) | CPU initiator avg/max % | CPU target avg/max % |
|---------|--------:|------------------:|-----------------:|------------------------:|---------------------:|
| *(idle baseline)* | — | — | — | 0.22 / 0.22 | 0.48 / 0.48 |
| LIBFABRIC | 1 | 43.5 | 43.5 | 0.24 / 0.26 | 0.42 / 0.48 |
| LIBFABRIC | 2 | 44.2 | 88.4 | 0.31 / 0.44 | 0.44 / 0.53 |
| LIBFABRIC | 4 | 43.6 | 175.3 | 0.30 / 0.40 | 0.44 / 0.56 |
| UCCL | 1 | 43.8 | 43.8 | 0.56 / 1.08 | 0.71 / 1.37 |
| UCCL | 2 | 43.8 | 87.7 | 1.12 / 2.76 | 1.27 / 3.15 |
| UCCL | 4 | 43.6 | 174.9 | 1.82 / 4.26 | 1.82 / 3.85 |

Per-stream BW stays ~44 GB/s; aggregate scales ≈×NUM_DEV. LIBFABRIC node CPU stays flat near the idle baseline. UCCL CPU scales roughly with agent count (~0.56 → 1.12 → 1.82% avg on initiator).

## 6. Cleanup between failed runs

If a run aborts mid-barrier, clear the etcd prefix before retrying:

```bash
kubectl -n raj-nixlbench exec deploy/etcd -- \
  etcdctl --endpoints=http://127.0.0.1:2379 del --prefix xferbench
# if etcdctl is not in the image, use an etcdctl ephemeral pod or etcd HTTP API
```

## 7. Tear down

```bash
kubectl delete -f manifests/nixlbench-pods.yaml
kubectl delete -f manifests/etcd.yaml
kubectl delete -f manifests/namespace.yaml
```

## Scripts

| Script | Purpose |
|--------|---------|
| [`scripts/install-nixlbench.sh`](scripts/install-nixlbench.sh) | Install build deps, stage NIXL link prefix, build/install nixlbench |
| [`scripts/install-uccl-p2p.sh`](scripts/install-uccl-p2p.sh) | Build UCCL P2P v0.1.1 + `libplugin_UCCL.so` only; write `uccl-env.sh` |
| [`scripts/check-nixlbench.sh`](scripts/check-nixlbench.sh) | Verify binary, libs, EFA, GPUs, LIBFABRIC smoke; `CHECK_UCCL=1` for UCCL |
| [`scripts/run-bench-sg.sh`](scripts/run-bench-sg.sh) | **Preferred** multi-process SG run (`ROLE=initiator\|target`, one NIXL agent per GPU — vLLM TP/DP-shaped) |
| [`scripts/run-bench.sh`](scripts/run-bench.sh) | Single-process debug only (`MODE=MG`); not used for reference results |
| [`scripts/run-sg-cpu-suite-host.sh`](scripts/run-sg-cpu-suite-host.sh) | Host orchestrator: LIBFABRIC+UCCL × fixed msg sizes + Prom node CPU → `/tmp/nixlbench-results/sg-cpu-suite.{csv,md}` |
| [`scripts/run-sg-ndev-cpu-suite-host.sh`](scripts/run-sg-ndev-cpu-suite-host.sh) | Host orchestrator: sweep `NUM_DEV` (1/2/4) at fixed msg size + Prom node CPU → `sg-ndev-cpu-suite.{csv,md}` |

## Notes

- NIXL is a **runtime** library already in the image. Building nixlbench only produces the missing CLI; it dynamically links to that NIXL (and thus to EFA libfabric for LIBFABRIC).
- UCCL install does **not** rebuild/replace core NIXL — only adds `libuccl_p2p` + `libplugin_UCCL.so`. Prefer `nixl_cu13` for the UCCL path (matches P/D).
- Do not use tip-of-`main` nixlbench / UCCL plugin against this image — pin to the wheel version (`v1.2.0` for `llm-d-aws:v0.8.1`).
- Hugepages: manifests request `hugepages-2Mi: 5120Mi`. Adjust if your nodes advertise a different amount (`kubectl describe node | grep hugepages`).
