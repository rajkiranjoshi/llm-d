# Building the libfabric-addon Init Container Image

This directory contains the Dockerfile and build tooling for the `libfabric-addon` init container. For what this image does and how to deploy it, see the [parent README](../README.md).

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
- **RHEL subscription bypass** — The RHAIIS image's `subscription-manager` dnf plugin is disabled and entitlement cert paths are injected directly into `redhat.repo` (see [rhel-subscription-setup.md](rhel-subscription-setup.md)).

## Prerequisites

The Dockerfile uses the RHAIIS target image itself as the builder base. This guarantees that `libplugin_LIBFABRIC.so` is compiled against the identical GCC, glibc, CUDA, libstdc++, and NIXL shared libraries that it will be loaded by at runtime.

This requires **RHEL entitlement certificates** for `dnf install` of `-devel` packages. See [rhel-subscription-setup.md](rhel-subscription-setup.md) for how to obtain them (no RHEL host required — uses a temporary container).

## Build

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

# 5. Full rebuild (no layer cache)
./build.sh --no-cache
```

### Configuration (`build.env`)

Copy `build.env.example` to `build.env` and edit. Key variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `BASE_IMAGE` | `registry.stage.redhat.io/rhaii/vllm-cuda-rhel9:3.5.0-1784900545` | RHAIIS image used as builder base |
| `ENTITLEMENT_DIR` | `./entitlement` | Path to RHEL entitlement PEM certs |
| `RHSM_CA_DIR` | `./rhsm-ca` | Path to Red Hat CDN CA cert |
| `ADDON_IMAGE_TAG` | `libfabric-addon:3.5.0-1784900545` | Local image tag |
| `ADDON_PUSH_TARGET` | *(unset)* | Remote registry tag (used with `--push`) |
| `NIXL_VERSION` | `v1.2.0` | Override NIXL source tag |
| `AWS_LIBFABRIC_VERSION` | `v2.3.1amzn4.0` | Override AWS libfabric source tag |

## Files

```
addon-docker-image/
├── Dockerfile                    # Multi-stage build: libfabric + NIXL plugin + addon image
├── build.sh                      # Build script (sources build.env, runs podman build)
├── build.env.example             # Template config: base image, cert paths, output tag
├── inject.sh                     # Init container entrypoint — copies artifacts to target volumes
├── pod-patch.yaml                # Example pod spec patch for standalone use
├── rhel-subscription-setup.md    # How to extract RHEL entitlement certs
├── README.md                     # This file
├── .gitignore                    # Ignores entitlement/, rhsm-ca/, build.env
├── entitlement/                  # (gitignored) RHEL entitlement PEM certs
└── rhsm-ca/                      # (gitignored) Red Hat CDN CA cert
```
