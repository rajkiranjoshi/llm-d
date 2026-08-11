# NIXL LIBFABRIC Posting Solutions: Deep Investigation

*Investigation date: 2026-08-05. Compared NIXL v1.2.0 (tag) vs main branch (post-v1.3.1).*

This document records the detailed investigation into why `NIXL_LIBFABRIC_NUM_THREADS` had no effect on our v1.2.0 benchmarks, and how the threading mechanism works in newer NIXL versions.

---

## Q1: How Do Env Vars Reach the LIBFABRIC Backend?

The env var mechanism is implemented in `src/utils/libfabric/libfabric_common.cpp`:

```cpp
// LibfabricUtils::getCustomStringParam (libfabric_common.cpp:228-251)
nixl_status_t
getCustomStringParam(const nixl_b_params_t &custom_params,
                     const std::string &key,
                     std::string &value) {
    std::string upper_key = key;
    std::transform(key.begin(), key.end(), upper_key.begin(), ::toupper);
    upper_key = std::string("NIXL_LIBFABRIC_") + upper_key;
    char *env_value = getenv(upper_key.c_str());
    if (env_value != nullptr) {
        value = env_value;
        return NIXL_SUCCESS;
    }
    nixl_b_params_t::const_iterator itr = custom_params.find(key);
    if (itr != custom_params.end()) {
        value = itr->second;
        return NIXL_SUCCESS;
    }
    return NIXL_ERR_NOT_FOUND;
}
```

`getCustomStringParam` (and its integer wrapper `getCustomIntParam`) checks the environment variable **first**, then falls back to `custom_params` (the init params dict). The env var naming convention is `NIXL_LIBFABRIC_<UPPER_CASE_KEY>`:

- `num_threads` → `NIXL_LIBFABRIC_NUM_THREADS`
- `split_batch_size` → `NIXL_LIBFABRIC_SPLIT_BATCH_SIZE`

**This mechanism existed in v1.2.0** — the env-var override code is identical. However, **no code in v1.2.0 ever calls it with the `num_threads` or `split_batch_size` keys** because the consuming code (`initPostThreadPool()`) did not exist yet.

---

## Q2: Was the Thread Pool Present in NIXL v1.2.0?

**No. The thread pool was NOT present in v1.2.0.**

| Feature | Commit | Date | First Released Tag |
|---------|--------|------|--------------------|
| Thread pool (`nixlLibfabricPostThreadPool`) | `ffc81680` — [PR #1581](https://github.com/ai-dynamo/nixl/pull/1581) | 2026-06-26 | **v1.3.1** |
| MPSC ring (PT-owns-endpoint) | `3d764d0e` — [PR #1949](https://github.com/ai-dynamo/nixl/pull/1949) | 2026-07-29 | **v1.4.0-rc1** |

**Version timeline:**
- v1.2.0 released 2026-05-29 — **no thread pool, no MPSC ring**
- v1.3.0 released 2026-06-15 — still no thread pool
- v1.3.1 released 2026-07-07 — **thread pool first appears here**
- v1.4.0-rc1 — adds the MPSC ring

Evidence from v1.2.0 source:

1. `grep -r "thread_pool\|ThreadPool\|PostThreadPool\|num_threads\|NUM_THREADS\|SPLIT_BATCH" src/plugins/libfabric/ src/utils/libfabric/` → **NO MATCHES**
2. `libfabric_plugin.cpp` in v1.2.0 registers **no backend options** (`{}` empty map):
   ```cpp
   // v1.2.0: libfabric_plugin.cpp line 29
   return libfabric_plugin_t::create(
       NIXL_PLUGIN_API_VERSION, "LIBFABRIC", "0.1.0", {}, {DRAM_SEG, VRAM_SEG});
   ```
3. The Python API in v1.2.0 only passes `num_threads` to `UCX` and `OBJ` backends:
   ```python
   # v1.2.0: _api.py line 246
   if bknd == "UCX" or bknd == "OBJ":
       init["num_threads"] = str(nixl_conf.num_threads)
   ```
   "LIBFABRIC" is NOT in this condition.

---

## Q3: Activation Condition (v1.3.1+ / main branch)

In the main branch, `postXfer()` decides whether to use the thread pool:

```cpp
// libfabric_backend.cpp:1466-1467 (main branch)
const bool use_post_pool = post_thread_pool_ && post_thread_count_ > 0 && desc_count > 0 &&
    static_cast<size_t>(desc_count) >= post_split_batch_size_;
```

All four conditions must be true:
1. `post_thread_pool_` is non-null (created if `num_threads > 0`)
2. `post_thread_count_ > 0`
3. `desc_count > 0`
4. `desc_count >= post_split_batch_size_` (default: 1024)

**For our workload:** with `--block-size 128`, all layers are batched into a single `postXfer` call with ~30K descriptors at ISL=24K. The default `split_batch_size=1024` should activate the pool.

---

## Q4: Logging When Threads Are Activated

In the main branch, `initPostThreadPool()` logs at DEBUG level:

```cpp
// libfabric_backend.cpp:604 (main)
if (post_thread_count_ > 0) {
    post_thread_pool_ = std::make_unique<nixlLibfabricPostThreadPool>(post_thread_count_);
    NIXL_DEBUG << "Libfabric descriptor post thread pool enabled with " << post_thread_count_
               << " threads, split_batch_size=" << post_split_batch_size_;
} else {
    NIXL_DEBUG << "Libfabric descriptor post thread pool disabled";
}
```

To verify from pod logs, set `NIXL_LOG_LEVEL=DEBUG` and look for `"Libfabric descriptor post thread pool enabled with N threads"`.

---

## Q5: Thread Safety with Shared Rails — `ep_mutex_` Analysis

### Model A: Direct posting (`enableProgTh=false`)

When the progress thread is disabled, `postRead` and `postWrite` are called directly and acquire `ep_mutex_` per rail:

```cpp
// libfabric_rail.cpp:1335 (main)
nixlLibfabricRail::postWrite(...) {
    while (true) {
        {
            const std::lock_guard<std::mutex> ep_lock(ep_mutex_);
            ret = fi_writemsg(endpoint, &msg, fi_flags | FI_REMOTE_CQ_DATA);
        }
        // ... retry on EAGAIN ...
    }
}
```

With `num_threads > 0`: multiple posting threads call `postRead`/`postWrite` concurrently on the **same rail's endpoint**, serializing on `ep_mutex_`. However, if descriptors spread across **different rails** (multi-rail striping), each rail has its own `ep_mutex_`, so there IS parallelism across rails. With 4 EFA NICs and 4 threads, each thread could post to a different rail concurrently.

### Model B: PT-owns-endpoint (`enableProgTh=true`)

When the progress thread is enabled, posting goes through the MPSC ring:

```
Caller thread → deferTransferRequest() → post_ring_.push(req) → [lock-free MPSC ring]
                                                                          ↓
Progress thread → progressCompletionQueue() → drainPostQueue() → fi_readmsg() / fi_writemsg()
```

- `drainPostQueue()` calls `fi_readmsg`/`fi_writemsg` **without** `ep_mutex_` (safe because only the progress thread touches the endpoint)
- Multiple producer threads push to the ring (lock-free via atomic fetch-add)
- **No lock contention on the endpoint**

**Thread pool + PT = best model:** Multiple threads prepare and enqueue descriptors in parallel (lock-free push). The single progress thread posts them serially but without mutex overhead.

---

## Q6: The MPSC Ring (PR #1949)

**Commit:** `3d764d0e` — [PR #1949](https://github.com/ai-dynamo/nixl/pull/1949)
**Date:** 2026-07-29
**First tag:** v1.4.0-rc1 (NOT in v1.3.1, NOT in v1.2.0)

The MPSC ring (`MpscRing<nixlLibfabricPostRequest>`) implements PT-owns-endpoint:
- Ring buffer size: configurable via `post_queue_size` (default 32K entries)
- Only initialized when `enableProgTh=true`
- `push()` is wait-free as long as ring has capacity (no CAS, uses fetch_add)
- `pop()` is single-consumer (progress thread only)

**Interaction with num_threads:** when both `enableProgTh=true` AND `num_threads > 0`:
1. `postXfer` divides descriptors into chunks → thread pool workers
2. Each worker calls `postXferDescriptors` → `prepareAndSubmitTransfer`
3. Since PT is enabled: `deferTransferRequest()` → `post_ring_.push()`
4. The ring supports Multiple Producers (MPSC = Multi-Producer Single-Consumer)
5. Progress thread pops and actually posts to the NIC

---

## Summary: Why Nothing Worked on v1.2.0

| What We Tried | Why It Failed |
|---|---|
| `NIXL_LIBFABRIC_NUM_THREADS=4` env var | Thread pool code didn't exist in v1.2.0; no code reads this var |
| `NIXL_LIBFABRIC_SPLIT_BATCH_SIZE=1024` env var | Same — no `initPostThreadPool()` to consume it |
| Python API `num_threads=4` for LIBFABRIC | v1.2.0 Python only passes `num_threads` to UCX/OBJ, not LIBFABRIC |
| Patching vLLM worker.py | Even if patched, the C++ backend ignores the param in v1.2.0 |

---

## Q7: Can the LIBFABRIC Backend Be Upgraded Independently of NIXL Core?

*Investigation date: 2026-08-11.*

Since both PR #1581 (thread pool) and PR #1949 (MPSC ring) are self-contained within the libfabric plugin code — with no changes to the core `postXfer()` / `checkXfer()` virtual interface — a natural question arises: why do we need to bump the entire NIXL version? Can't we just use a newer LIBFABRIC backend `.so` with an older NIXL core?

### Plugin Loading Mechanism: dlopen + API Version Check

NIXL uses a genuine `dlopen`-based plugin system. Each backend ships as `libplugin_<NAME>.so`, discovered at runtime:

```cpp
// src/core/nixl_plugin_manager.cpp
nixlBackendPlugin *plugin = init();
if (plugin->api_version != NIXL_PLUGIN_API_VERSION) {   // currently = 1
    NIXL_ERROR << "Plugin API version mismatch for " << plugin_path
               << ": expected " << NIXL_PLUGIN_API_VERSION
               << ", got " << plugin->api_version;
    dlclose(handle);
    return nullptr;
}
```

Plugins are discovered from `NIXL_PLUGIN_DIR`, or a `plugins/` directory relative to `libnixl.so`. There's also a static-linking mode (`-Dstatic_plugins=LIBFABRIC,UCX,...`) where plugins are compiled directly into the core library.

### The Plugin Interface

The interface is defined across three headers in `src/api/cpp/backend/`:

| Header | Purpose |
|--------|---------|
| `backend_plugin.h` | C-ABI plugin struct: `create_engine`, `destroy_engine`, `get_plugin_name`, etc. |
| `backend_engine.h` | C++ virtual base class (`nixlBackendEngine`): `postXfer()`, `checkXfer()`, `registerMem()`, etc. |
| `backend_aux.h` | Init params, descriptor types passed between core and backend |

**`NIXL_PLUGIN_API_VERSION` has stayed at `1` since v1.2.0 and remains `1` on main (v1.4.0-dev).** The `nixlBackendEngine` vtable layout is also unchanged between these versions.

### Thread Pool and MPSC Ring: Self-Contained in Theory

Both features are 100% inside the libfabric plugin code — no changes to the core virtual interface:

| Feature | Files Changed | Core API Impact |
|---------|--------------|-----------------|
| Thread pool (PR #1581) | `src/plugins/libfabric/libfabric_backend.{cpp,h}`, `libfabric_plugin.cpp` | **None** |
| MPSC ring (PR #1949) | `src/plugins/libfabric/` + `src/utils/libfabric/` | **None** |

### Why You Still Can't Swap the `.so` (Practical Constraints)

Despite the clean API boundary, three factors make it unsafe to drop a newer `libplugin_LIBFABRIC.so` into an older NIXL:

**1. Shared utility library dependency.** The libfabric plugin doesn't just link against NIXL core — it depends on a separate `libfabric_utils` shared library (`src/utils/libfabric/`). PR #1949 adds `MpscRing`, `drainPostQueue()`, and new parameters to `prepareAndSubmitTransfer()` in this utility library. The v1.2.0 utility library doesn't have these symbols — the plugin would fail to load.

**2. Core header changes.** The plugin `.so` is compiled against core headers like `backend_aux.h`, which changed between v1.2.0 and main — new types (`nixlStrideDesc`, `nixlStrideDescList`), changed defaults in `nixlBackendInitParams`. Memory layout mismatches between the plugin and core would cause crashes.

**3. No ABI stability contract.** The version check is a single integer (`1`), not a semantic version or ABI hash. There's no capability negotiation or feature flags. The `backend_plugin.h` header explicitly notes: *"Plugins must be compiled with the same C++ standard and a compatible libstdc++ ABI as the NIXL core library."* The `nixlBackendEngine` base class uses C++ virtual methods — reordering or adding any virtual method changes the vtable layout. While this **hasn't happened** between v1.2.0 and main, there's no mechanism to detect if it does.

### Could You Cherry-Pick Just Enough?

In theory:
1. Start from the NIXL v1.2.0 tag
2. Cherry-pick PR #1581 (thread pool) — it's self-contained in `src/plugins/libfabric/`
3. Rebuild the entire NIXL from source

This would give you `NIXL_LIBFABRIC_NUM_THREADS=4` without bumping to v1.3.2. But you'd still rebuild all of NIXL (just from a different commit), lose any bug fixes in v1.3.x, and need to verify no build system conflicts.

For PR #1949 (MPSC ring), cherry-picking is harder because it touches `src/utils/libfabric/` (the utility library), which has other changes between v1.2.0 and v1.4.0.

### UCCL Comparison

UCCL follows the exact same pattern: same `meson.build` dual-mode structure, same `nixlBackendPluginCreator<>` template, same `NIXL_PLUGIN_API_VERSION = 1`. It's not independently versioned either — shares the monorepo release cycle. No backend in NIXL has its own release train.

### Verdict

The LIBFABRIC backend is **architecturally pluggable** (dlopen, clean virtual interface, separate `.so`) but **practically tied to NIXL core releases** due to C++ vtable ABI sensitivity, header-level type dependencies, and shared utility library coupling. The practical upgrade unit is "all of NIXL" — which in a container-based deployment means bumping the NIXL version in the container image.
