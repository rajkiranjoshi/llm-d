# vllm-ucx-multiproc-hotfix

Helm chart for AKS that renders ConfigMap **`vllm-ucx-multiproc-hotfix`** with three keys overlaid into the llm-d-cuda image at `/opt/vllm-source/vllm/v1/executor/`:

| ConfigMap key | Overlay target | Purpose |
|---------------|----------------|---------|
| `multiproc_executor.py` | `multiproc_executor.py` | TP > 1 executor: calls `set_worker_net_device` in `worker_main`; `prefetch_gpu_pci_map` in parent |
| `uniproc_executor.py` | `uniproc_executor.py` | TP = 1 executor: calls `set_worker_net_device` in `_init_executor` |
| `vllm_net_devices.py` | `vllm_net_devices.py` | Shared module: GPU-NIC PCIe mapping, `set_worker_net_device` entry point |

No chart values are needed; the only required pod env var is **`VLLM_GPU_NIC_PCIE_MAPPING`** on the workload (set in `values_aks.yaml`).

## `VLLM_GPU_NIC_PCIE_MAPPING`

Comma-separated **`gpu_bdf=nic_bdf`** pairs. Example:

```
00000001:00:00.0=0101:00:00.0,00000002:00:00.0=0102:00:00.0
```

GPU keys must match **`nvidia-smi --query-gpu=pci.bus_id`** per NVML index (after `normalize_pci` rules). Both sides accept variable-width domain fields (`00000001:…` = `0001:…` = `1:…`).

### How it works

1. **TP > 1 (`MultiprocExecutor`):** parent runs one `nvidia-smi` and stores the index-to-BDF map as JSON in `VLLM_INTERNAL_GPU_PCI_BY_INDEX_JSON` (inherited by workers). Each worker calls `set_worker_net_device(local_rank)` which resolves `GPU BDF → NIC BDF → sysfs RDMA name → UCX_NET_DEVICES={rdma_name}:1`.

2. **TP = 1 (`UniProcExecutor`):** single-process; `set_worker_net_device(local_rank)` calls `nvidia-smi` once inline (no prefetch needed).

3. If `VLLM_GPU_NIC_PCIE_MAPPING` is **not set**, `set_worker_net_device` is a no-op.

### NIXL / P/D disaggregation

This guide's PD configs are **TP-only per pod** (scale via Kubernetes replicas). `EngineCore_DP0` in logs means DP rank 0 even when world size is 1. Multi-DP on a single node may offset CUDA indices vs `local_rank`; not currently supported by this mapping.

## Updating after a vLLM bump

Copy the three files from the vllm submodule tree:

```bash
for f in multiproc_executor.py uniproc_executor.py vllm_net_devices.py; do
  cp vllm/vllm/v1/executor/$f \
     guides/pd-disaggregation/ms-pd/charts/vllm-ucx-multiproc-hotfix/$f
done
```

Then `helmfile apply -e aks` (or upgrade only `vllm-ucx-hotfix-*`).
