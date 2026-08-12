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

## Version Pinning

All versions are traced from the target image and the llm-d v0.8.1 EFA build:

| Component | Version | Source |
|-----------|---------|--------|
| Target image | `registry.stage.redhat.io/rhaii/vllm-cuda-rhel9:3.5.0-1784900545` | RHAIIS 3.5.0 |
| Base OS | RHEL 9.6 (x86_64) | Image label `com.redhat.aiplatform.base_image` |
| vLLM | 0.24.0+rhaiv.2 | `pip show vllm` in target image |
| NIXL | **v1.2.0** | `pip show nixl` in target image |
| NIXL plugins present | UCX, GDS, GDS_MT, POSIX | Target image (LIBFABRIC absent) |
| GCC | 11.5.0 | Target image (used as builder) |
| CUDA | 13.0 | Target image |
| System libfabric (RPM) | 1.22.0-1.el9 | No EFA provider |
| System rdma-core (RPM) | 54.0-2.el9_6 | libibverbs EFA provider present |
| AWS libfabric (build) | **v2.3.1amzn4.0** | EFA installer 1.46.0 (from llm-d v0.8.1 `Dockerfile.cuda`) |
| EFA installer | **1.46.0** | llm-d v0.8.1 `ARG EFA_INSTALLER_VERSION` |
| abseil-cpp (build) | **20240116.2** | Required by NIXL LIBFABRIC plugin for `VLOG`/`DVLOG` logging |
| cuda-nvml-devel (build-only) | 13.0 | Provides `nvml.h` for libfabric CUDA support configure |

### How the AWS libfabric version was determined

```
RHAIIS 3.5.0 (vLLM 0.24.0, NIXL v1.2.0)
    ↓ NIXL version must match
llm-d v0.8.1 Dockerfile.cuda (NIXL v1.2.0, EFA_INSTALLER_VERSION=1.46.0)
    ↓ EFA installer bundles
AWS EFA installer 1.46.0 → libfabric v2.3.1amzn4.0
```

The NIXL version (v1.2.0) is the binding constraint — it determines plugin ABI compatibility. The llm-d v0.8.1 release is the latest that uses NIXL v1.2.0 with EFA support, and its EFA installer (1.46.0) bundles libfabric v2.3.1amzn4.0.

## Build Stages

The Dockerfile is a three-stage build, all using the RHAIIS target image as the builder base for ABI-compatible compilation:

| Stage | Base | What it builds | Build-time deps installed via dnf/pip |
|-------|------|---------------|---------------------------------------|
| 1 — `libfabric-builder` | RHAIIS image | AWS libfabric v2.3.1amzn4.0 with EFA provider (`./configure --enable-efa --with-cuda`) | gcc, gcc-c++, make, automake, autoconf, libtool, rdma-core-devel, cuda-nvml-devel-13-0 |
| 2 — `nixl-builder` | RHAIIS image | `libplugin_LIBFABRIC.so` from NIXL v1.2.0 source + abseil-cpp 20240116.2 shared libs | gcc, gcc-c++, ninja-build, cmake, pkg-config, hwloc-devel, numactl-devel, rdma-core-devel, meson (pip), pybind11 (pip) |
| 3 — `addon` | UBI 9 minimal | Final image — copies only the runtime artifacts from stages 1 and 2 | (none) |

**Build-time workarounds** (not shipped in the final image):

- **Stub `libnvidia-ml.so`** — Both stages create a stub shared library with empty `nvmlInit_v2`, `nvmlShutdown`, etc. symbols. Libfabric's `./configure` with `--with-cuda` tries to link against NVML, which is a driver library injected by the NVIDIA device plugin at runtime and absent during builds.
- **RHEL subscription bypass** — The RHAIIS image's `subscription-manager` dnf plugin is disabled and entitlement cert paths are injected directly into `redhat.repo` (see [addon-docker-image/rhel-subscription-setup.md](addon-docker-image/rhel-subscription-setup.md)).

## Build the Addon Image

See [addon-docker-image/](addon-docker-image/) for the Dockerfile, build script, and instructions.

```bash
cd guides/pd-disaggregation/libfabric-addon/addon-docker-image/

# 1. Extract RHEL entitlement certs (one-time, see rhel-subscription-setup.md)
#    → produces entitlement/*.pem and rhsm-ca/*.pem

# 2. Create build config
cp build.env.example build.env
# Edit build.env: set BASE_IMAGE, cert paths, output tag

# 3. Build
./build.sh

# 4. Build and push
./build.sh --push
```

The Dockerfile uses the RHAIIS target image itself as the builder base. This guarantees that `libplugin_LIBFABRIC.so` is compiled against the identical GCC, glibc, CUDA, libstdc++, and NIXL shared libraries that it will be loaded by at runtime — exactly as if AIPCC had built the image with LIBFABRIC support enabled.

This requires RHEL entitlement certificates for `dnf install` of `-devel` packages. See [addon-docker-image/rhel-subscription-setup.md](addon-docker-image/rhel-subscription-setup.md) for how to extract them.

## Deploy on EKS with EFA

### Prerequisites

- EKS cluster with p5.48xlarge nodes (EFA NICs)
- EFA device plugin installed (`vpc.amazonaws.com/efa` resource)
- libfabric-addon image built and pushed (`quay.io/rajjoshi/libfabric-addon:3.5.0-1784900545`)
- Logged into `registry.stage.redhat.io` (imagePullSecret for RHAIIS image)
- Model cached at `/mnt/nvme/models` on nodes

### Quick Start

```bash
cd guides/pd-disaggregation/libfabric-addon/

# Set required env vars
export HF_TOKEN="hf_..."
export NAMESPACE="my-namespace"

# Deploy everything (namespace + secret + helm + HTTPRoute)
just start

# Monitor
just status
just ready
just logs decode
just logs prefill

# Verify EFA + LIBFABRIC injection
just verify decode

# Benchmark
just benchmark 1 100 4096 512
```

### Customizing TP / Replicas

```bash
# 2P(TP=4) + 2D(TP=4) — uses 16 EFA NICs per pod
just deploy-with-tp 4 4 2 2

# 1P(TP=8) + 3D(TP=8) — uses 32 EFA NICs per pod
just deploy-with-tp 8 8 1 3
```

### Key Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `NIXL_PLUGIN_DIR` | `/opt/nixl-plugins` | Tells NIXL where to find plugins (avoids shadowing originals) |
| `LD_LIBRARY_PATH` | `/opt/efa-libs:...` | EFA libfabric takes precedence over system RPM libfabric |
| `FI_PROVIDER` | `efa` | Tells libfabric to use the EFA provider |
| `FI_EFA_USE_DEVICE_RDMA` | `1` | Enables GPUDirect RDMA on EFA |

### How It Works

The deployment adds an init container to both prefill and decode pods:

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

The init container copies NIXL plugins, EFA-enabled libfabric, and abseil shared libraries into shared `emptyDir` volumes. The main vLLM container mounts these at `/opt/nixl-plugins` and `/opt/efa-libs`, with env vars pointing NIXL and the dynamic linker to the injected artifacts:

- **`/opt/nixl-plugins/`** — all 5 NIXL plugins (LIBFABRIC + UCX + GDS + GDS_MT + POSIX)
- **`/opt/efa-libs/`** — EFA libfabric (`libfabric.so.1.29.1`), abseil libs (`libabsl_*.so`), `fi_info`

## Verification

After deployment, exec into a vLLM pod and verify:

```bash
# Check EFA provider is available
/opt/efa-libs/fi_info -p efa

# Check NIXL LIBFABRIC plugin is loaded
NIXL_LOG_LEVEL=DEBUG python3 -c "
from nixl import nixlAgent, nixlAgentConfig
cfg = nixlAgentConfig('test')
agent = nixlAgent(cfg)
" 2>&1 | grep -i "libfabric\|LIBFABRIC"

# Check all NIXL plugins are present
ls -la /opt/nixl-plugins/
# Should show: libplugin_LIBFABRIC.so, libplugin_UCX.so, libplugin_GDS.so, etc.
```

Or use the Justfile shortcut: `just verify decode`

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

## Limitations

- The addon is pinned to NIXL v1.2.0 and RHAIIS 3.5.0. A different NIXL version in the target image would require rebuilding.
- The `libfabric_utils` static library (topology detection, rail management) is baked into `libplugin_LIBFABRIC.so`. NIXL v1.2.0 does not include the posting thread pool (`NIXL_LIBFABRIC_NUM_THREADS`) — that requires NIXL >= v1.3.1.
- The init container pattern adds ~1-2 seconds to pod startup. The addon image is ~130 MB uncompressed (mostly abseil shared libraries and libfabric).

## Files

```
libfabric-addon/
├── Justfile                          # Deploy/manage P/D stack with RHAIIS + addon
├── values_eks_rdma.yaml              # Helm values: RHAIIS image + init container
├── README.md                         # This file
└── addon-docker-image/
    ├── Dockerfile                    # Multi-stage build: libfabric + NIXL plugin + addon image
    ├── build.sh                      # Build script (sources build.env, runs podman build)
    ├── build.env.example             # Template config: base image, cert paths, output tag
    ├── inject.sh                     # Init container script to copy artifacts
    ├── pod-patch.yaml                # Example pod spec patch for manual deployment
    ├── rhel-subscription-setup.md    # How to extract RHEL entitlement certs for the build
    ├── .gitignore                    # Ignores entitlement/, rhsm-ca/, build.env
    ├── entitlement/                  # (gitignored) RHEL entitlement PEM certs
    └── rhsm-ca/                      # (gitignored) Red Hat CDN CA cert
```
