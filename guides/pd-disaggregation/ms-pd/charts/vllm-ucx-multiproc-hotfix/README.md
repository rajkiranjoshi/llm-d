# vllm-ucx-multiproc-hotfix

Helm chart for AKS that renders ConfigMap **`vllm-ucx-multiproc-hotfix`** with a single key: **`multiproc_executor.py`** (overlays `/opt/vllm-source/vllm/v1/executor/multiproc_executor.py` in the llm-d-cuda image).

## Chart values

| Value | Default | Meaning |
|-------|---------|---------|
| **`usePcieGpuNicMapping`** | `false` | If `true`, ConfigMap content comes from **`multiproc_executor-pcie.py`** (GPU PCIe → NIC PCIe → `UCX_NET_DEVICES`). If `false`, from **`multiproc_executor.py`** (per-rank **`mlx5_<local_rank>:1`** when **`VLLM_UCX_NET_DEVICES_PER_RANK=1`**). |

Set this on the **`vllm-ucx-hotfix-*`** release in [`helmfile.yaml.gotmpl`](../../../helmfile.yaml.gotmpl) (`guides/pd-disaggregation`, `-e aks`).

## Baseline variant (`usePcieGpuNicMapping: false`)

- Env **`VLLM_UCX_NET_DEVICES_PER_RANK=1`**: each worker sets **`UCX_NET_DEVICES=mlx5_<local_rank>:1`** (IB/RoCE-style `:1` port suffix).
- If **`VLLM_GPU_NIC_PCIE_MAPPING`** is set while this variant is deployed, workers log a **warning** (mapping is ignored unless you switch variant).

## PCIe mapping variant (`usePcieGpuNicMapping: true`)

**Does not** set **`mlx5_<local_rank>:1`** from rank alone — use the **baseline** variant (`usePcieGpuNicMapping: false`) + **`VLLM_UCX_NET_DEVICES_PER_RANK=1`** for that.

This variant **only** applies when **`VLLM_GPU_NIC_PCIE_MAPPING`** is non-empty:

1. Env **`VLLM_GPU_NIC_PCIE_MAPPING`**: comma-separated **`gpu_bdf=nic_bdf`** pairs (use **`=`** between GPU and NIC BDFs). Example:

   `00000001:00:00.0=0000da:00:00.0,00000002:00:00.0=0000db:00:00.0`

   GPU keys must match **`nvidia-smi --query-gpu=pci.bus_id`** per NVML index (after the same **`normalize_pci`** rules as NIC keys).

   **BDF spelling:** both sides may use either **`domain:bus:dev.fn`** (domain width varies, e.g. `00000001:…` vs `0001:…`) or **`bus:dev.fn`** when domain is **0** (e.g. `40:00.0` ≡ `0000:40:00.0`). Matching is by numeric domain/bus/device/function, not string equality.

2. **GPU PCI lookup:** **`MultiprocExecutor._init_executor`** runs **one** **`nvidia-smi --query-gpu=index,pci.bus_id`** (no `-i`), stores JSON in **`VLLM_INTERNAL_GPU_PCI_BY_INDEX_JSON`** for workers. **`set_worker_gpu_nic_mapping`** indexes by **`local_rank`**. If prefetch fails, each worker falls back to one full-table query.

   **`local_rank`** is the NVML GPU index (**TP-only / DP=1**). vLLM does **not** set **`CUDA_VISIBLE_DEVICES`** per worker.

3. **NIC → RDMA name:** for each **`/sys/class/infiniband/<name>/device`**, the symlink target’s **basename** is the NIC **BDF** (see baseline README sysfs note). Compare with mapping NIC keys after **`normalize_pci`**.

4. **`UCX_NET_DEVICES`:** **`{rdma_name}:1`** (port **`1`** fixed for typical single-port HCAs).

### NIXL / P/D disaggregation and DP

NIXL (KV transfer) and UCX are compatible with vLLM **data parallel** in general, but **this guide’s PD configs are TP-only inside each pod** (scale via Kubernetes replicas, not necessarily `data_parallel_size > 1` per engine). **`EngineCore_DP0`** in logs often means DP rank **0** even when world size is **1**.

**Caveat:** if you run **multi-DP on a single node**, `gpu_worker` may offset CUDA indices vs raw tensor **`local_rank`**; this helper does not apply that offset — use **DP=1** or extend the mapping logic.

## Updating after a vLLM bump

Refresh **both** upstream-aligned sources from the submodule, then re-apply edits:

```bash
cp vllm/vllm/v1/executor/multiproc_executor.py \
  guides/pd-disaggregation/ms-pd/charts/vllm-ucx-multiproc-hotfix/multiproc_executor.py
# Merge UCX baseline / PCIe blocks back into multiproc_executor.py; copy to multiproc_executor-pcie.py and re-merge PCIe helpers.
```

Easiest workflow: copy submodule file → **`multiproc_executor.py`** → duplicate to **`multiproc_executor-pcie.py`** → re-apply the PCIe-only helper block + `worker_main` branch from git history or this README.

Then **`helmfile apply -e aks`** (or upgrade only `vllm-ucx-hotfix-*`).
