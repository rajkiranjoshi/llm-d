# KServe / LLMInferenceService Deployment with Libfabric Addon

Deploy RHAIIS + libfabric-addon using KServe's `LLMInferenceService` CRD on EKS with EFA.

This is an alternative to the Helm-based deployment in the parent directory. Both produce the same result: vLLM serving with NIXL LIBFABRIC backend over EFA RDMA.

## Prerequisites

- EKS cluster with p5.48xlarge GPU nodes (EFA NICs)
- EFA device plugin installed (`vpc.amazonaws.com/efa` resource)
- Model downloaded to NVMe HF cache on GPU nodes (`/mnt/nvme/models/hub/`)
- Image pull secrets created in the namespace:
  - `rhai-pull-secret` for `registry.stage.redhat.io`
  - `quay-pull-secret` for `quay.io/rajjoshi/libfabric-addon`

## How It Works

Each LLMISvc deployment uses two init containers:

1. **`link-model`** — Creates symlinks from `/mnt/models/` (where KServe's vLLM command expects the model) into the HF cache snapshot directory on the mounted NVMe `hostPath`. The `MODEL_NAME` env var is converted to the HF cache directory convention (`org/model` -> `models--org--model`). This avoids re-downloading the model and uses the local NVMe cache directly.

2. **`inject-libfabric`** — Copies the NIXL LIBFABRIC plugin, EFA-enabled libfabric libraries, and abseil dependencies into `emptyDir` volumes shared with the main container (same as the Helm-based deployment).

The KServe controller also auto-injects a **`llm-d-routing-sidecar`** as a native Kubernetes sidecar (init container with `restartPolicy: Always`). This handles P/D routing coordination with the EPP — no manual sidecar config is needed.

The main vLLM container mounts:
- `/mnt/models` (emptyDir with symlinks) — model files for vLLM
- `/model-store` (hostPath to `/mnt/nvme/models`) — backing store for symlinks
- `/opt/nixl-plugins` (emptyDir) — injected NIXL plugins
- `/opt/efa-libs` (emptyDir) — injected EFA libfabric + abseil

GPU node tolerations (`nvidia.com/gpu:NoSchedule`) are **not** needed in the YAML — the Kubernetes `ExtendedResourceToleration` admission plugin auto-injects them for any pod requesting `nvidia.com/gpu` resources.

## Deploy

### Single-node (no P/D)

```bash
kubectl apply -f llmisvc-single-node.yaml -n <namespace>
```

Deploys 1 replica with TP=4, 16 EFA NICs, libfabric addon, and NVMe model cache.

### P/D Disaggregated

```bash
kubectl apply -f llmisvc-pd.yaml -n <namespace>
```

Deploys 1 prefill (TP=4) + 1 decode (TP=4) with KV cache transfer via NIXL LIBFABRIC over EFA RDMA. Both pods get the full libfabric addon and NVMe model mount.

### LLMInferenceServiceConfig (Optional)

If cluster admin RBAC is available, apply the reusable baseRef:

```bash
kubectl apply -f efa-libfabric-config.yaml -n <namespace>
```

This provides the libfabric injection as a shared config that LLMISvc resources can reference via `spec.baseRefs`. The self-contained YAMLs above don't require this.

## Verification

After pods reach `Ready` state:

```bash
# 1. Check init container logs — link-model should find and symlink the model
kubectl logs <pod> -n <ns> -c link-model
# Expected:
#   Linking RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic from /model-store/hub/models--RedHatAI--Llama-3.3-70B-Instruct-FP8-dynamic/snapshots/<hash>/
#   Created 24 symlinks in /mnt/models

# 2. Check init container logs — inject-libfabric should copy plugins and libs
kubectl logs <pod> -n <ns> -c inject-libfabric
# Expected:
#   [libfabric-addon] Copying NIXL plugins (UCX + GDS + POSIX + LIBFABRIC)...
#   [libfabric-addon] Done. Files injected:
#     Plugins: 5 .so files
#     EFA libs: 176 library files

# 3. Check NIXL plugins are mounted in the main container
kubectl exec <pod> -n <ns> -- ls /opt/nixl-plugins/
# Expected: libplugin_LIBFABRIC.so  libplugin_UCX.so  libplugin_GDS.so  etc.

# 4. Check EFA provider is available via fi_info
kubectl exec <pod> -n <ns> -- /opt/efa-libs/fi_info -p efa
# Expected: provider: efa, type: FI_EP_RDM, fabric: efa-direct

# 5. Check env vars
kubectl exec <pod> -n <ns> -- env | grep -E "FI_|NIXL|LD_LIBRARY"
# Expected: FI_PROVIDER=efa, NIXL_PLUGIN_DIR=/opt/nixl-plugins, etc.

# 6. Check vLLM logs for NIXL/LIBFABRIC initialization
kubectl logs <pod> -n <ns> -c main | grep -E "NIXL|NixlConnector|LIBFABRIC"
# Expected:
#   NIXL is available
#   NixlConnector setting KV cache layout to HND for better xfer performance.
#   kv_connector_extra_config={'backends': ['LIBFABRIC']}

# 7. For P/D: check NIXL LIBFABRIC backend registers memory on EFA rails
kubectl logs <pod> -n <ns> -c main | grep libfabric_rail_manager
# Expected: "Registered memory on <N> rails, mem_type=1"

```

## Switching Models

To use a different model, update the model name in these places:

| Field | Single-node | P/D |
|---|---|---|
| `spec.model.name` | 1 | 1 |
| `spec.model.uri` (`hf://...`) | 1 | 1 |
| `link-model` init container `MODEL_NAME` env | 1 (decode) | 2 (decode + prefill) |
| **Total** | **3** | **4** |

All values use the same HuggingFace model ID (e.g. `RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic`). The `link-model` script auto-converts `org/model` to the HF cache convention `models--org--model`.

The model must already be downloaded to the NVMe HF cache on GPU nodes. The host path may differ if the cache is in a different location (default: `/mnt/nvme/models`).

To change TP or replica counts, update `spec.parallelism.tensor` and `spec.replicas`.

## Files

```
kserve/
├── README.md                    # This file
├── efa-libfabric-config.yaml    # LLMISvcConfig baseRef (optional, admin-only)
├── llmisvc-single-node.yaml     # Single-node LLMISvc (TP=4, EFA, libfabric addon)
└── llmisvc-pd.yaml              # P/D disaggregated LLMISvc (1P+1D, TP=4, EFA)
```
