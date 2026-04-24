# AKS Cluster Context for llm-d Deployment

This file captures the state of the AKS cluster and the llm-d deployment layer
so a new Cursor window can pick up where the previous session left off.

## Cluster Details

| Property | Value |
|---|---|
| **Cluster Name** | `aks-llmd-ndH100` |
| **Resource Group** | `llmd-raj` |
| **Region** | South Central US |
| **GPU SKU** | `Standard_ND40rs_v2` (8x H100 80GB HBM3 per node) |
| **GPU Nodes** | 2 (`aks-gpunp-12730235-vmss000000`, `vmss000001`) |
| **CPU Workers** | 2-node `cpunp` pool (`Standard_D5_v2`) |
| **System Pool** | 2-node `systemnp` pool |
| **Kubernetes** | v1.34.4 |
| **IB Networking** | 8x ConnectX-7 400G HCAs per GPU node (`mlx5_0`–`mlx5_7`), `mlx5_8` = control plane |

## Nodepools & Taints

- **gpunp**: tainted `nvidia.com/gpu=present:NoSchedule` — only GPU workloads schedule here
- **systemnp**: tainted `CriticalAddonsOnly=true:NoSchedule` — system pods only
- **cpunp**: no taints — general CPU workloads
- Kubernetes `ExtendedResourceToleration` admission controller auto-injects GPU tolerations for pods requesting `nvidia.com/gpu`
- **No explicit tolerations or nodeSelectors needed** in pod specs for GPU workloads

## Operators & Infrastructure

| Component | Namespace | Notes |
|---|---|---|
| NVIDIA GPU Operator v25.10.0 | `gpu-operator` | Driver v580.126.20, RDMA enabled |
| NVIDIA Network Operator v26.1.0 | `network-operator` | MOFED/DOCA drivers, shared IB device plugin (`rdma/shared_ib`) |
| NRI ulimit-adjuster | `kube-system` | Raises memlock for annotated pods (but `IPC_LOCK` capability is preferred for RDMA) |
| llm-d Monitoring | `llm-d-monitoring` | Prometheus + Grafana with TLS, DOCA telemetry scraping |

## RDMA / IB Configuration

- Device plugin exposes `rdma/shared_ib` (63 per node)
- DOCA Telemetry Service scrapes IB counters → Prometheus via `ServiceMonitor`
- `port_xmit_data` / `port_rcv_data` counters are in **4-byte words** (multiply by 4 for bytes/s)
- Each HCA sustains ~395 Gbps (~49.4 GB/s) per `ib_write_bw`
- `IPC_LOCK` capability is required for RDMA pinned memory (NIXL will fail without it)
- Reference: `values_ocp_rdma.yaml` adds `IPC_LOCK`, `SYS_RAWIO`, `NET_ADMIN`, `NET_RAW`

## Pre-downloaded Models (on NVMe at `/mnt/local-nvme-storage/models`)

Available on both GPU nodes:
- `RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic`
- `RedHatAI/Qwen3-30B-A3B-FP8-dynamic`
- `deepseek-ai/DeepSeek-V3-0324`
- `meta-llama/Llama-4-Scout-17B-16E-Instruct`
- `meta-llama/Llama-3.1-8B-Instruct`
- `mistralai/Mistral-Small-3.1-24B-Instruct-2503`
- `zai-org/GLM-Z1-32B-0414`

## llm-d Deployment Layer (this repo)

**Branch**: `aks-llmd-ndH100` (based on upstream `main`)

### Files added/modified:

| File | Purpose |
|---|---|
| `guides/pd-disaggregation/Justfile` | AKS P/D: setup, deploy, destroy, poker, benchmark (`cd` there or `-f` + `--working-directory`) |
| `guides/pd-disaggregation/.env.example` | Optional `NAMESPACE`, `HF_TOKEN`, TP/replica overrides |
| `guides/pd-disaggregation/ms-pd/values_aks.yaml` | AKS-specific Helm values for P/D disagg |
| `guides/pd-disaggregation/helmfile.yaml.gotmpl` | Modified to add `aks` environment |
| `poker/poker.yaml` | Lightweight benchmarking pod |

### Key design decisions:

1. **No explicit GPU tolerations** — `ExtendedResourceToleration` handles this automatically
2. **No explicit nodeSelector for GPU** — resource-based scheduling places GPU pods correctly
3. **`rdma/shared_ib: 1`** in resource requests — gives each container access to all 8 HCAs
4. **NVMe model cache** via `hostPath: /mnt/local-nvme-storage/models` — models pre-downloaded by infra repo
5. **NRI ulimit annotations** are set in `helmfile.yaml.gotmpl` for the `aks` environment (raises memlock to 16GiB) — consider switching to `IPC_LOCK` capability instead (cleaner, no annotation dependency)
6. **Per-user namespace isolation** via `NAMESPACE` env var (defaults to `$USER-dev`)

### Quickstart:

```bash
cd guides/pd-disaggregation
cp .env.example .env   # optional: HF_TOKEN, NAMESPACE, optional TP/replica env vars
just start              # setup + helmfile -e aks + HTTPRoute
just ready && just status
just start-poker && just poke
just logs               # decode logs (default)
just logs prefill       # prefill logs
just stop               # P/D only: destroy (helmfile -e aks) + HTTPRoute; poker: just stop-poker
just grafana            # Grafana → http://localhost:3000
```

### Default P/D configuration (values_aks.yaml):

- **Model**: `RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic`
- **Decode**: 1 replica, TP=8 (1 full node), port 8200
- **Prefill**: 2 replicas, TP=4 (4 GPUs each), port 8000
- **KV Transfer**: NIXL connector (`NixlConnector`, `kv_role=kv_both`)
- **Max model length**: 32000

### Monitoring (already deployed on cluster):

- Grafana: from `guides/pd-disaggregation`, run `just grafana` → http://localhost:3000 (see [monitoring docs](docs/monitoring/README.md))
- Prometheus: port-forward kube-prometheus Prometheus service in `llm-d-monitoring` if needed
- Dashboard: "RDMA Network — HCA Traffic" — shows per-HCA TX/RX bandwidth per node
- vLLM metrics: PodMonitors auto-created by helmfile (port `vllm`, path `/metrics`)

## Infra Repo Reference

The cluster infrastructure is managed in a separate repo:
- **Path**: `/Users/rajjoshi/workspace/llm-d-xks-aks-1`
- **Branch**: `feat/cluster-enhancements`
- **Remote**: `https://github.com/rajkiranjoshi/llm-d-xks-aks.git`
- **Key files**: `Makefile`, `user-mgmt.sh`, `aks-cluster-ctl.sh`, `monitoring/`, `local-storage/`, `nri-config/`, `network-operator/`

## Open Items / TODO

- [ ] Add `IPC_LOCK` capability to vllm containers in `values_aks.yaml` and remove NRI ulimit annotation dependency from `helmfile.yaml.gotmpl`
- [ ] Test P/D deployment end-to-end with the Justfile
- [ ] Add P/D sweep automation (multiple configs) to Justfile
- [ ] Validate vLLM metrics are scraped by llm-d-monitoring Prometheus
