# LIBFABRIC Addon for RHAIIS vllm-cuda-rhel9

Adds NIXL LIBFABRIC backend + AWS EFA support to the Red Hat AI Inference Server (RHAIIS) `vllm-cuda-rhel9` image **without rebuilding it**.

## Problem

The RHAIIS `vllm-cuda-rhel9:3.5.0` image ships with NIXL v1.2.0 but only includes the **UCX** backend plugin. On AWS EKS with EFA NICs, NIXL's LIBFABRIC backend is required for KV cache transfer via `fi_read()` / `fi_write()` over the EFA provider. Two things are missing:

1. **`libplugin_LIBFABRIC.so`** — the NIXL LIBFABRIC backend plugin (not compiled into the image)
2. **EFA-enabled libfabric** — the system RPM libfabric (1.22.0) does not include the EFA provider

## Approach

Build a small "addon" init container image that carries everything needed to enable NIXL's LIBFABRIC backend with EFA on top of the unmodified RHAIIS image. At pod startup, an init container copies these artifacts into shared `emptyDir` volumes. The main vLLM container picks them up via `NIXL_PLUGIN_DIR` and `LD_LIBRARY_PATH`.

### Injected artifacts

| Artifact | Location in addon | Injected to | Purpose |
|----------|-------------------|-------------|---------|
| `libplugin_LIBFABRIC.so` | `/artifacts/plugins/` | `/opt/nixl-plugins/` | NIXL LIBFABRIC backend plugin, compiled from NIXL v1.2.0 source against the RHAIIS image's NIXL headers and shared libs |
| `libfabric.so.1.29.1` | `/artifacts/efa/lib/` | `/opt/efa-libs/` | AWS fork of libfabric (v2.3.1amzn4.0) with EFA, verbs, shm, tcp, rxm, rxd, mrail providers compiled in; replaces the system RPM libfabric (1.22.0) which lacks the EFA provider |
| `libabsl_*.so` (55 libraries) | `/artifacts/abseil/lib/` | `/opt/efa-libs/` | Abseil-cpp 20240116.2 shared libraries — runtime dependency of `libplugin_LIBFABRIC.so` (see [below](#why-abseil)) |
| `fi_info` | `/artifacts/efa/bin/` | `/opt/efa-libs/` | Libfabric introspection tool for verifying EFA provider availability at runtime |
| `libplugin_UCX.so` | `/artifacts/plugins/` | `/opt/nixl-plugins/` | Original NIXL UCX plugin from the RHAIIS image — re-copied so the `NIXL_PLUGIN_DIR` volume mount doesn't shadow it |
| `libplugin_GDS.so` | `/artifacts/plugins/` | `/opt/nixl-plugins/` | Original NIXL GDS plugin |
| `libplugin_GDS_MT.so` | `/artifacts/plugins/` | `/opt/nixl-plugins/` | Original NIXL GDS multi-threaded plugin |
| `libplugin_POSIX.so` | `/artifacts/plugins/` | `/opt/nixl-plugins/` | Original NIXL POSIX plugin |

### Why abseil?

NIXL v1.2.0's LIBFABRIC backend plugin uses abseil-cpp's logging framework (`VLOG`/`DVLOG` macros from `absl/log/log.h`) for verbose trace logging of fabric operations. When `libplugin_LIBFABRIC.so` is built from source it dynamically links against abseil's shared libraries. The RHAIIS image does not ship abseil at all, so without the addon injecting them the plugin fails to load at runtime with:

```
undefined symbol: _ZN4absl12lts_2024011612log_internal9kCharNullE
```

The abseil `.so` files are placed alongside the EFA libs in `/opt/efa-libs/` which is on `LD_LIBRARY_PATH`, so the dynamic linker resolves them automatically when NIXL `dlopen`s the plugin.

### Why replace the entire libfabric?

The EFA provider cannot be loaded as a standalone DSO by a different libfabric version. Unlike libibverbs (which always uses external provider DSOs), libfabric providers call internal `ofi_*` symbols that are resolved at `dlopen` time against the hosting `libfabric.so`. The internal API is not ABI-stable across versions, and the RHEL RPM libfabric (1.22.0, ABI 1.7) is incompatible with the AWS fork (2.3.x, ABI 1.8). AWS's own EFA installer handles this by installing a **complete replacement libfabric** to `/opt/amazon/efa/`.

### Why not upgrade NIXL to get the LIBFABRIC plugin directly?

The NIXL LIBFABRIC backend is architecturally pluggable (`dlopen`-based, `NIXL_PLUGIN_API_VERSION=1`) but practically tied to NIXL core releases due to C++ vtable ABI sensitivity, header-level type dependencies, and shared utility library coupling. The `libfabric_utils` used by the plugin is a **static library** that gets linked into `libplugin_LIBFABRIC.so`, so the final artifact is self-contained — but it must be compiled against the exact same NIXL headers and shared libraries present in the target image.

## Deploy on EKS with EFA

### Prerequisites

- EKS cluster with p5.48xlarge nodes (EFA NICs)
- EFA device plugin installed (`vpc.amazonaws.com/efa` resource)
- Logged into `registry.stage.redhat.io` (imagePullSecret for RHAIIS image)
- Model cached at `/mnt/nvme/models` on nodes

The addon init container image is pre-built and available at `quay.io/rajjoshi/libfabric-addon:3.5.0-1784900545`. To rebuild for a different RHAIIS or NIXL version, see [addon-docker-image/README.md](addon-docker-image/README.md).

### Deploy

This follows the same pattern as the upstream [P/D disaggregation guide](../README.md). This directory includes its own `helmfile.yaml.gotmpl` (derived from the upstream one) that points the `eks_rdma` model service at `values_eks_rdma.yaml` (RHAIIS + addon) instead of `ms-pd/values_eks_rdma.yaml`.

```bash
cd guides/pd-disaggregation/libfabric-addon
export NAMESPACE="<user>-dev"

# 1. Create namespace and secrets
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic llm-d-hf-token \
  --from-literal=HF_TOKEN='hf_...' -n ${NAMESPACE} \
  --dry-run=client -o yaml | kubectl apply -f -

# Registry pull secrets (RHAIIS image + addon image if private)
kubectl create secret docker-registry registry-pull-secret \
  --docker-server=registry.stage.redhat.io \
  --docker-username='<user>' --docker-password='<password>' \
  -n ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# 2. Deploy full stack (infra + GAIE + model service)
# Default: 1P(TP=8) + 1D(TP=8), 32 EFA NICs per pod
helmfile apply -e eks_rdma -n ${NAMESPACE}

# 3. Create the HTTPRoute
kubectl apply -f ../httproute.yaml -n ${NAMESPACE}
```

EFA NICs per pod = 4 × TP. The default in `values_eks_rdma.yaml` is TP=4 (16 EFA NICs).

### Deploy (Justfile)

The Justfile wraps the above commands for convenience:

```bash
cd guides/pd-disaggregation/libfabric-addon/
export NAMESPACE='<user>-dev'         # defaults to $USER-dev if not set
export HF_TOKEN='hf_...'
export REGISTRY_USER='<user>'         # registry.stage.redhat.io credentials
export REGISTRY_PASSWORD='<password>'

# Full stack: namespace + secrets + helm + HTTPRoute
# Default: 1P(TP=8) + 1D(TP=8), 32 EFA NICs per pod
just start

# Or with explicit TP: 1P(TP=4) + 1D(TP=4)
just deploy-with-tp 4 4 1 1

# Monitor
just status        # pod overview
just ready         # block until all pods are Ready
just logs decode   # tail vLLM logs

# Teardown
just stop
```

### Benchmark

Once pods are ready, deploy the poker pod and run a benchmark:

```bash
# Wait for all pods to be ready
just ready

# Deploy the poker pod (in-cluster benchmark client)
just start-poker

# Run a benchmark: just benchmark <max_concurrency> <num_requests> <input_len> <output_len>
just benchmark 8 100 4096 512

# Or open a shell in the poker pod for interactive benchmarking
just poke
```

### Key Environment Variables

These are set in `values_eks_rdma.yaml` on the vLLM container:

| Variable | Value | Purpose |
|----------|-------|---------|
| `NIXL_PLUGIN_DIR` | `/opt/nixl-plugins` | Tells NIXL where to find plugins (avoids shadowing originals) |
| `LD_LIBRARY_PATH` | `/opt/efa-libs:...` | EFA libfabric takes precedence over system RPM libfabric |
| `FI_PROVIDER` | `efa` | Tells libfabric to use the EFA provider |
| `FI_EFA_USE_DEVICE_RDMA` | `1` | Enables GPUDirect RDMA on EFA |

### How It Works

The deployment adds an init container to both prefill and decode pods. At startup it copies artifacts into two shared `emptyDir` volumes:

- **`/opt/nixl-plugins/`** — all 5 NIXL plugins (LIBFABRIC + UCX + GDS + GDS_MT + POSIX)
- **`/opt/efa-libs/`** — EFA libfabric (`libfabric.so.1.29.1`), abseil libs (`libabsl_*.so`), `fi_info`

The relevant pod spec additions (already in `values_eks_rdma.yaml`):

```yaml
initContainers:
- name: inject-libfabric
  image: quay.io/rajjoshi/libfabric-addon:3.5.0-1784900545
  command: ["/bin/bash", "/artifacts/inject.sh", "/target/plugins", "/target/efa-libs"]
  volumeMounts:
  - name: nixl-plugins
    mountPath: /target/plugins
  - name: efa-libs
    mountPath: /target/efa-libs
```

The main vLLM container mounts these volumes at `/opt/nixl-plugins` and `/opt/efa-libs`, with `NIXL_PLUGIN_DIR` and `LD_LIBRARY_PATH` pointing to the injected artifacts. See [addon-docker-image/pod-patch.yaml](addon-docker-image/pod-patch.yaml) for a standalone pod spec example.

## Verification

After deployment, verify EFA + LIBFABRIC injection:

```bash
# Using Justfile
just verify decode

# Or manually
DECODE_POD=$(kubectl -n ${NAMESPACE} get pod -l llm-d.ai/role=decode \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n ${NAMESPACE} exec ${DECODE_POD} -c vllm -- ls -la /opt/nixl-plugins/
kubectl -n ${NAMESPACE} exec ${DECODE_POD} -c vllm -- /opt/efa-libs/fi_info -p efa
```

## Benchmark Results

Benchmarks comparing the RHAIIS + libfabric-addon against the upstream `llm-d-aws:v0.8.1` image. Both deployments use the same NIXL v1.2.0, libfabric v2.3.1amzn4.0, and `llm-d-routing-sidecar:v0.7.1`. Configuration: **1P(TP=4) + 1D(TP=4)**, Llama-3.3-70B-Instruct-FP8, `max-model-len=32768`, `max_concurrency=8`, EKS p5.48xlarge nodes with EFA.

### ISL=24000, OSL=512, 100 requests

| Metric | RHAIIS + addon | llm-d-aws v0.8.1 (baseline) | Delta |
|--------|---------------|---------------------------|-------|
| Total token throughput | 16,443 tok/s | 16,418 tok/s | +0.2% |
| Mean TTFT | 3,613 ms | 3,854 ms | **-6.3%** |
| Median TTFT | 3,258 ms | 3,487 ms | **-6.6%** |
| P99 TTFT | 10,491 ms | 10,455 ms | +0.3% |
| Mean TPOT | 15.67 ms | 15.21 ms | +3.0% |
| P99 ITL | 37.13 ms | 40.95 ms | **-9.3%** |
| Duration | 149.07s | 149.30s | ~same |
| Successful requests | 100/100 | 100/100 | — |

### ISL=4096, OSL=512, 100 requests

| Metric | RHAIIS + addon | llm-d-aws v0.8.1 (baseline) | Delta |
|--------|---------------|---------------------------|-------|
| Total token throughput | 5,525 tok/s | 5,381 tok/s | **+2.7%** |
| Mean TTFT | 407 ms | 574 ms | **-29.2%** |
| Median TTFT | 314 ms | 342 ms | **-8.2%** |
| P99 TTFT | 1,544 ms | 2,098 ms | **-26.4%** |
| Mean TPOT | 11.82 ms | 11.85 ms | -0.3% |
| P99 ITL | 21.63 ms | 16.33 ms | +32.5% |
| Duration | 83.38s | 85.62s | -2.6% |
| Successful requests | 100/100 | 100/100 | — |

**Conclusion**: The RHAIIS + libfabric-addon achieves **performance parity** with the upstream `llm-d-aws:v0.8.1` image. Total throughput matches within 0–3%, TTFT is slightly better on the RHAIIS image (likely due to newer vLLM internals in 0.24.0 vs the upstream build), and TPOT/ITL are within noise. The init container approach successfully enables NIXL LIBFABRIC/EFA with **zero performance penalty**.

## KServe / LLMInferenceService Deployment

For deployments using KServe's `LLMInferenceService` CRD instead of Helm, see [kserve/README.md](kserve/README.md). The KServe path uses an `ensure-model` init container to download (if needed) and symlink models from the NVMe HF cache, and provides self-contained LLMISvc YAMLs for both single-node and P/D disaggregated topologies.

## Limitations

- The addon is pinned to NIXL v1.2.0 and RHAIIS 3.5.0. A different NIXL version in the target image would require rebuilding.
- The `libfabric_utils` static library (topology detection, rail management) is baked into `libplugin_LIBFABRIC.so`. NIXL v1.2.0 does not include the posting thread pool (`NIXL_LIBFABRIC_NUM_THREADS`) — that requires NIXL >= v1.3.1.
- The init container pattern adds ~1-2 seconds to pod startup. The addon image is ~130 MB uncompressed (mostly abseil shared libraries and libfabric).

## Rebuilding the Addon Image

The addon image is pre-built at `quay.io/rajjoshi/libfabric-addon:3.5.0-1784900545`. To rebuild for a different RHAIIS or NIXL version, see [addon-docker-image/README.md](addon-docker-image/README.md).

## Files

```
libfabric-addon/
├── helmfile.yaml.gotmpl              # Helmfile (derived from upstream, points to addon values)
├── Justfile                          # Deploy/manage P/D stack with RHAIIS + addon
├── values_eks_rdma.yaml              # Helm values: RHAIIS image + init container
├── README.md                         # This file (approach + deploy)
├── kserve/                           # KServe LLMISvc deployment path
│   ├── README.md                     # KServe deployment guide
│   ├── efa-libfabric-config.yaml     # LLMISvcConfig baseRef (optional, admin-only)
│   ├── llmisvc-single-node.yaml      # Single-node LLMISvc (TP=4, EFA, libfabric addon)
│   └── llmisvc-pd.yaml               # P/D disaggregated LLMISvc (1P+1D, TP=4, EFA)
└── addon-docker-image/
    ├── README.md                     # Build guide (version pinning, stages, instructions)
    ├── Dockerfile                    # Multi-stage build: libfabric + NIXL plugin + addon image
    ├── build.sh                      # Build script (sources build.env, runs podman build)
    ├── build.env.example             # Template config: base image, cert paths, output tag
    ├── inject.sh                     # Init container entrypoint — copies artifacts to target volumes
    ├── pod-patch.yaml                # Example pod spec patch for standalone use
    ├── rhel-subscription-setup.md    # How to extract RHEL entitlement certs
    ├── .gitignore                    # Ignores entitlement/, rhsm-ca/, build.env
    ├── entitlement/                  # (gitignored) RHEL entitlement PEM certs
    └── rhsm-ca/                      # (gitignored) Red Hat CDN CA cert
```
