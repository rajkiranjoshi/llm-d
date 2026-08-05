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
