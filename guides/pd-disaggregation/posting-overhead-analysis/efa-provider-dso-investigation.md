# Can the AWS EFA Provider Be Built as a Standalone DSO for a Different Libfabric?

*Investigation date: 2026-08-11.*

## TL;DR — Verdict

**No. This approach is not feasible.** The EFA provider cannot be extracted from the AWS libfabric fork and loaded as a standalone DSO into upstream libfabric 1.22.0. The fundamental blockers are:

1. **Major version mismatch**: RHEL's libfabric 1.22.0 is API version 1.22 / ABI 1.7. The AWS fork v2.3.1amzn4.0 is based on upstream v2.3.x (API version 2.x / ABI 1.8). While libfabric 2.x maintains ABI backward compatibility for *applications*, provider DSOs are deeply coupled to internal APIs that changed across this boundary.

2. **Pervasive internal API coupling**: The EFA provider is not a thin shim — it calls dozens of internal `ofi_*` utility functions (memory registration caches, HMEM subsystem, monitor infrastructure, parameter management) that are not part of the stable public ABI and have changed between 1.22 and 2.x.

3. **No provider ABI stability contract**: Libfabric has no mechanism to negotiate or verify internal provider ABI compatibility. The only version check is `provider->fi_version >= FI_VERSION(1, 3)`, which is a floor, not a compatibility gate.

The correct approach is to **replace the entire libfabric** with the AWS build, which is exactly what the AWS EFA installer does (installing into `/opt/amazon/efa/`).

---

## 1. Libfabric External Provider Mechanism

### 1.1 Provider Discovery and Loading

Libfabric discovers external providers via `dlopen` in `src/fabric.c`. The flow:

```
fi_ini()
  → ofi_ordered_provs_init()     // pre-register known provider names (efa, verbs, tcp, ...)
  → ofi_load_dl_prov()           // load external DSOs
      → reads FI_PROVIDER_PATH env var (or uses PROVDLDIR default)
      → for each directory: scandir() for files matching "*-fi.so"
      → ofi_reg_dl_prov(lib_path):
          dlhandle = dlopen(lib, RTLD_NOW)
          inif = dlsym(dlhandle, "fi_prov_ini")
          ofi_register_provider(inif(), dlhandle)
  → ofi_register_provider(EFA_INIT, NULL)  // register built-in providers
```

**Source**: [`src/fabric.c` lines 662-688, 779-855](https://github.com/ofiwg/libfabric/blob/main/src/fabric.c)

Key details:
- External providers must be named `lib<name>-fi.so` (the suffix is defined by `FI_LIB_SUFFIX` = `"fi.so"`)
- They must export a single symbol: `fi_prov_ini()`, which returns a `struct fi_provider*`
- `FI_PROVIDER_PATH` supports colon-separated directories, `@` prefix for discovery-order priority, and `+/path/to/lib.so` for preferred providers
- External DSO providers are loaded **before** built-in providers, so a DSO provider can shadow a built-in one

### 1.2 The Provider Interface (`struct fi_provider`)

The public provider contract is defined in `include/rdma/providers/fi_prov.h`:

```c
struct fi_provider {
    uint32_t version;       // provider's own version
    uint32_t fi_version;    // libfabric API version it was built against
    struct fi_context context;  // opaque, used internally for ofi_prov_context
    const char *name;
    int (*getinfo)(uint32_t version, const char *node, const char *service,
                   uint64_t flags, const struct fi_info *hints,
                   struct fi_info **info);
    int (*fabric)(struct fi_fabric_attr *attr, struct fid_fabric **fabric,
                  void *context);
    void (*cleanup)(void);
};
```

This struct layout is the same between libfabric 1.x and 2.x — it's a C struct with function pointers, not a C++ vtable.

### 1.3 Version Checks During Registration

In `ofi_register_provider()` (`src/fabric.c` lines 515-592), the only version check is:

```c
if (provider->fi_version < FI_VERSION(1, 3)) {
    FI_INFO(&core_prov, FI_LOG_CORE,
        "provider has unsupported FI version "
        "(provider %d.%d != libfabric %d.%d); ignoring\n", ...);
    goto cleanup;
}
```

This is a **floor check only** — it rejects providers that claim to support a version older than 1.3. There is **no ceiling check** that rejects providers claiming a *newer* version than the core. A provider built against 2.x claiming `fi_version = FI_VERSION(2, 5)` would pass this check when loaded by libfabric 1.22.

In `fi_getinfo()`, there's an additional check:

```c
if (FI_VERSION_LT(prov->provider->fi_version, version)) {
    // skip — provider too old for what the application requested
}
```

Since `FI_VERSION(2, 5)` > `FI_VERSION(1, 22)`, a 2.x provider would also pass this check.

**There is no ABI hash, capability negotiation, or internal version handshake.**

---

## 2. AWS EFA Provider Architecture

### 2.1 Source Location and Structure

The EFA provider lives in `prov/efa/` within the libfabric tree. It's a large provider (~80 source files) organized as:

```
prov/efa/
├── src/
│   ├── efa_prov.c          # Provider init (EFA_INI entry point)
│   ├── efa_fabric.c        # fi_fabric implementation
│   ├── efa_domain.c        # fi_domain implementation
│   ├── efa_ep.c            # endpoint implementation
│   ├── efa_cq.c            # completion queue
│   ├── efa_mr.c            # memory registration
│   ├── efa_av.c            # address vector
│   ├── efa_env.c           # environment variable handling
│   ├── efa_direct_ope.c    # EFA-direct data path operations
│   ├── efa_data_path_direct.c
│   └── rdm/                # RDM (reliable datagram) sub-layer
│       ├── efa_rdm_ep_*.c
│       ├── efa_rdm_pke_*.c # packet engine
│       ├── efa_rdm_ope.c   # operation engine
│       └── ...
├── test/                   # unit tests (cmocka + gtest)
└── docs/
```

### 2.2 Build Modes: Built-in vs DSO

The build mode is controlled by `--enable-efa=<mode>`:
- `--enable-efa=yes` (default): compiled into `libfabric.so` directly
- `--enable-efa=dl`: built as a separate `libefa-fi.la` → `libefa-fi.so`
- `--enable-efa=no`: disabled entirely

The Makefile logic in `prov/efa/Makefile.include`:

```makefile
if HAVE_EFA_DL
pkglib_LTLIBRARIES += libefa-fi.la
libefa_fi_la_SOURCES = $(_efa_files) $(_efa_headers) $(common_srcs)
libefa_fi_la_LDFLAGS = -module -avoid-version -shared -export-dynamic $(efa_LDFLAGS)
libefa_fi_la_LIBADD = $(linkback) $(efa_LIBS)
else !HAVE_EFA_DL
src_libfabric_la_SOURCES += $(_efa_files) $(_efa_headers)
endif
```

When built as DL, the provider's entry point is defined via the `FI_EXT_INI` macro:

```c
// fi_prov.h
#define FI_EXT_INI \
    __attribute__((visibility ("default"),EXTERNALLY_VISIBLE)) \
    struct fi_provider* fi_prov_ini(void)

// ofi_prov.h
#if (HAVE_EFA) && (HAVE_EFA_DL)
# define EFA_INI FI_EXT_INI      // exports fi_prov_ini()
# define EFA_INIT NULL            // core doesn't call it directly
```

So a DSO-mode EFA provider exports `fi_prov_ini()` which returns `&efa_prov`.

### 2.3 What the EFA Provider Uses from Libfabric Internals

The EFA provider init (`efa_prov.c`) calls these internal functions when built as DL:

```c
EFA_INI {
#if HAVE_EFA_DL
    ofi_mem_init();
    ofi_hmem_init();
    ofi_monitors_init();
    ofi_params_init();
#endif
    // ... provider-specific init ...
}
```

Beyond init, the EFA provider pervasively uses internal libfabric APIs throughout its implementation:

| Internal API Category | Example Functions | Purpose |
|---|---|---|
| Memory subsystem | `ofi_mem_init()`, `ofi_mem_fini()` | Internal allocator setup |
| HMEM (heterogeneous memory) | `ofi_hmem_init()`, `ofi_copy_from_hmem_iov()` | GPU/accelerator memory support |
| Memory monitors | `ofi_monitors_init()`, `ofi_monitors_cleanup()` | MR cache invalidation |
| Parameters | `fi_param_define()`, `fi_param_get_*()` | Config variable registration |
| MR cache | `ofi_mr_cache_*()` | Memory registration caching |
| Utility providers | `ofi_prov_ctx()`, `ofi_set_prov_type()` | Provider type classification |
| Locking | `ofi_mutex_*()` | Thread synchronization |
| Info manipulation | `fi_dupinfo()`, `fi_freeinfo()`, `fi_allocinfo()` | fi_info lifecycle |
| Logging | `FI_WARN()`, `FI_INFO()`, `FI_DBG()` | Debug output |

These are **not** part of the stable public ABI. They are internal symbols of `libfabric.so`.

### 2.4 System Dependencies

The EFA provider requires:
- **rdma-core** (libibverbs, libefa): provides the verbs-level device access (`ibv_*` and `efadv_*` functions)
- **EFA kernel driver**: `amzn-drivers` kernel module for EFA device access
- Optionally: CUDA, Neuron SDK (for HMEM/GPU support)

---

## 3. Version Compatibility Analysis

### 3.1 Version Mapping

| Component | API Version | ABI Version | `fi_version()` returns |
|---|---|---|---|
| RHEL 9.6 libfabric RPM | 1.22.0 | 1.7 | `FI_VERSION(1, 22)` = `0x00010016` |
| AWS fork v2.3.1amzn4.0 | 2.3.x (based on `ofiwg/libfabric` v2.3.x branch) | 1.8 | `FI_VERSION(2, 3+)` = `0x00020003+` |
| Upstream main (HEAD) | 2.6.0a1 | 1.8+ | `FI_VERSION(2, 6)` = `0x00020006` |

The AWS fork v2.3.1amzn4.0 release notes state: *"This release is based on ofiwg/libfabric@e33a074 from ofiwg/libfabric v.2.3.x branch."*

### 3.2 The ABI Compatibility Story

Libfabric's ABI versioning ([ofiwg/libfabric wiki: ABI Versions](https://github.com/ofiwg/libfabric/wiki/ABI-Versions)) tracks the **public symbol ABI** (`libfabric.map`):

| ABI Version | Libfabric Versions | Changes |
|---|---|---|
| 1.7 | 1.20–1.22 | `fi_getinfo`, `fi_freeinfo`, `fi_dupinfo` updated |
| 1.8 | 2.0+ | New ABI version for 2.x series |

Libfabric 2.0 explicitly maintains **application-level ABI compatibility** with 1.x: "Version 2 is ABI compatible with version 1, but not API compatible." This means compiled 1.x applications can link against 2.x `libfabric.so` without relinking.

**However, this ABI guarantee is for applications, not for providers.** Provider DSOs don't just use the public ABI — they link against internal symbols.

### 3.3 Internal ABI: Why Cross-Version Loading Fails

The EFA provider DSO, when `dlopen`'d, resolves symbols against the hosting `libfabric.so`. These include:

**1. Internal functions that may have changed signatures or been renamed:**
- `ofi_hmem_init()` — the HMEM subsystem evolved significantly between 1.22 and 2.x
- `ofi_monitors_init()` / `ofi_monitors_cleanup()` — memory monitor infrastructure
- `ofi_mr_cache_*()` — MR cache API
- `ofi_params_init()` — parameter system initialization

**2. Internal data structures used via inline functions:**
- `ofi_prov_ctx()` casts `prov->context` (a `struct fi_context`) to `struct ofi_prov_context`:
  ```c
  struct ofi_prov_context {
      enum ofi_prov_type type;
      bool disable_logging;
      bool disable_layering;
  };
  ```
  If `ofi_prov_context` gains new fields in 2.x (or the `ofi_prov_type` enum changes values), the provider and core would disagree on the layout.

**3. The `fi_info` allocation model changed in 2.x:**
  The 2.x API requires all `fi_info` structs to be allocated by libfabric (not hand-crafted). While the struct layout is the same, the internal allocation patterns and hidden fields may differ.

**4. New internal symbols in 2.x not present in 1.22:**
  Any new internal function used by the EFA provider in 2.x that doesn't exist in 1.22's `libfabric.so` would cause `dlopen(lib, RTLD_NOW)` to fail with unresolved symbols.

### 3.4 The `fi_version` Field

The EFA provider sets:

```c
struct fi_provider efa_prov = {
    .version = OFI_VERSION_DEF_PROV,
    .fi_version = OFI_VERSION_LATEST,  // = FI_VERSION(FI_MAJOR_VERSION, FI_MINOR_VERSION)
    ...
};
```

When compiled from the 2.3.x tree, `OFI_VERSION_LATEST` = `FI_VERSION(2, 3+)`. The hosting libfabric 1.22 doesn't check for an upper bound, so the version field alone wouldn't prevent loading. **The failure would happen earlier**, at `dlopen(RTLD_NOW)` time, when unresolved internal symbols prevent the DSO from loading.

---

## 4. AWS EFA Installer Approach

### 4.1 What the Installer Does

The AWS EFA installer (`aws-efa-installer`) installs a **complete, self-contained libfabric** into `/opt/amazon/efa/`:

```
/opt/amazon/efa/
├── lib64/
│   ├── libfabric.so.1 → libfabric.so.1.x.0    # complete libfabric with EFA built-in
│   └── libfabric/
│       └── (optional DSO providers)
├── bin/
│   └── fi_info
└── include/
```

The installer does NOT:
- Install just the EFA provider DSO
- Install alongside the system libfabric in a compatible way
- Use `FI_PROVIDER_PATH` to add EFA to an existing libfabric

It installs a **full replacement libfabric** (with EFA built-in) into a separate prefix. Applications use it via `LD_LIBRARY_PATH=/opt/amazon/efa/lib64:$LD_LIBRARY_PATH`.

### 4.2 Why AWS Chose Full Replacement

This design choice reflects the reality that the EFA provider is deeply coupled to libfabric internals. The AWS fork:
- Carries patches to the libfabric core (not just the EFA provider)
- Uses internal APIs that may differ from the upstream version at any given point
- Optimizes the core + provider as a unit

AWS's own documentation for NIXL on EFA explicitly instructs:
```bash
meson setup . nixl --prefix=/usr/local/nixl -Dlibfabric_path=/opt/amazon/efa
```

---

## 5. Alternative Approaches

### 5.1 LD_LIBRARY_PATH Replacement (Recommended)

Install the AWS EFA libfabric into `/opt/amazon/efa/` and set `LD_LIBRARY_PATH` so the container uses it instead of the RHEL RPM version:

```bash
export LD_LIBRARY_PATH=/opt/amazon/efa/lib64:$LD_LIBRARY_PATH
```

This **replaces the entire libfabric** at runtime. The RHEL RPM's `libfabric.so` is still on disk but not loaded.

**Pros**: This is the supported approach. AWS tests this configuration.
**Cons**: Replaces the system libfabric entirely (other providers like verbs may behave differently).

### 5.2 Rebuild RHEL Libfabric with EFA (Theoretical)

Take the upstream libfabric 1.22.0 source, apply the EFA provider from the same 1.22.x tree (if it has EFA support), and rebuild:

```bash
./configure --enable-efa=yes --with-rdma-core=/path/to/rdma-core
```

**Problem**: Upstream libfabric 1.22.0 does include the EFA provider in its source tree (`prov/efa/`), but the RHEL RPM was built without it (likely because RHEL doesn't ship rdma-core with EFA support, or the EFA kernel driver wasn't available). You could rebuild from source with `--enable-efa`, but this requires the EFA rdma-core libraries and kernel driver to be present at build time.

### 5.3 Container Image with AWS Libfabric Pre-installed

Build a container image that includes the AWS EFA libfabric from the start, rather than trying to add it at runtime:

```dockerfile
FROM base-image
RUN curl -O https://efa-installer.amazonaws.com/aws-efa-installer-latest.tar.gz && \
    tar xf aws-efa-installer-latest.tar.gz && \
    cd aws-efa-installer && \
    ./efa_installer.sh -y --skip-kmod
ENV LD_LIBRARY_PATH=/opt/amazon/efa/lib64:$LD_LIBRARY_PATH
```

---

## 6. Summary of Findings

| Question | Answer |
|---|---|
| Can EFA be built as a standalone DSO? | **Yes** — `--enable-efa=dl` produces `libefa-fi.so`. |
| Can that DSO be loaded by a *different* libfabric? | **No** — the DSO resolves internal symbols against the hosting libfabric. |
| Is there a provider ABI stability contract? | **No** — only a minimum version floor check (`fi_version >= 1.3`). |
| What upstream version is AWS v2.3.1amzn4.0? | Based on upstream v2.3.x branch (`ofiwg/libfabric@e33a074`). |
| Can a 2.x provider DSO load into 1.22? | **No** — unresolved internal symbols at `dlopen` time; ABI 1.8 vs 1.7 mismatch. |
| How does the AWS EFA installer work? | Installs a complete replacement libfabric into `/opt/amazon/efa/`. |
| Has anyone used cross-version external providers? | No evidence of this being supported or attempted. The `FI_PROVIDER_PATH` mechanism is designed for providers built from the **same** libfabric tree. |

### The Fundamental Insight

Libfabric's external provider mechanism (`FI_PROVIDER_PATH`, `libfoo-fi.so`, `fi_prov_ini()`) is designed for **deployment flexibility** (choosing where provider DSOs are installed), not for **version decoupling**. Providers are compiled against the same source tree as the core and use the same internal headers and APIs. The mechanism lets you separate the binaries, not the versions.

This is analogous to Linux kernel modules: you can build a kernel module as a separate `.ko` file, but it must be built against the same kernel source and loaded by the same kernel version.
