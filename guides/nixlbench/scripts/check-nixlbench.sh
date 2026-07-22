#!/usr/bin/env bash
# Verify nixlbench install + EFA/NIXL readiness inside an llm-d-aws pod.
# Exits non-zero on any failure.
set -euo pipefail

NIXLBENCH_PREFIX="${NIXLBENCH_PREFIX:-/usr/local/nixlbench}"
NIXL_LINK_PREFIX="${NIXL_LINK_PREFIX:-/opt/nixl-for-bench}"
EXPECT_GPUS="${EXPECT_GPUS:-4}"
EXPECT_EFA_MIN="${EXPECT_EFA_MIN:-1}"
SKIP_LIBFABRIC_SMOKE="${SKIP_LIBFABRIC_SMOKE:-0}"
CHECK_UCCL="${CHECK_UCCL:-0}"
# Image may set UCCL_PREFIX=/opt/uccl (prebaked stub). Our in-pod install uses /opt/uccl-p2p.
UCCL_P2P_PREFIX="${UCCL_P2P_PREFIX:-/opt/uccl-p2p}"

# Use nixlbench env for baseline checks (cu12-friendly). UCCL env is sourced
# only in the UCCL section — mixing cu13 LD_LIBRARY_PATH breaks nixlbench --help.
# shellcheck disable=SC1091
[[ -f /usr/local/nixlbench/env.sh ]] && source /usr/local/nixlbench/env.sh

export PATH="${NIXLBENCH_PREFIX}/bin:/opt/amazon/efa/bin:/opt/ucx/bin:/usr/local/bin:/opt/vllm/bin:${PATH}"
# Prefer wheel libs when env.sh not present yet.
# Do NOT prepend /usr/local/lib64 — system etcd/grpc clashes with the wheel.
if [[ -z "${NIXL_PLUGIN_DIR:-}" ]]; then
  for d in \
    /opt/vllm/lib/python3.12/site-packages/.nixl_cu12.mesonpy.libs \
    /opt/vllm/lib64/python3.12/site-packages/.nixl_cu12.mesonpy.libs
  do
    if [[ -d "${d}" ]]; then
      export LD_LIBRARY_PATH="${d}:${LD_LIBRARY_PATH:-}"
      export NIXL_PLUGIN_DIR="${d}/plugins"
      break
    fi
  done
  for d in \
    /opt/vllm/lib/python3.12/site-packages/nixl_cu12.libs \
    /opt/vllm/lib64/python3.12/site-packages/nixl_cu12.libs
  do
    [[ -d "${d}" ]] && export LD_LIBRARY_PATH="${d}:${LD_LIBRARY_PATH:-}" && break
  done
  export LD_LIBRARY_PATH="/opt/amazon/efa/lib64:/opt/amazon/efa/lib:/opt/ucx/lib64:/opt/ucx/lib:${NIXL_LINK_PREFIX}/lib64:/usr/lib64:${LD_LIBRARY_PATH:-}"
fi

PASS=0
FAIL=0
ok() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }

echo "=== check-nixlbench ==="
echo "host=$(hostname)  date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 1. Binary
if command -v nixlbench >/dev/null 2>&1; then
  ok "nixlbench on PATH: $(command -v nixlbench)"
else
  bad "nixlbench not on PATH"
fi

if [[ -x "${NIXLBENCH_PREFIX}/bin/nixlbench" ]]; then
  ok "binary exists: ${NIXLBENCH_PREFIX}/bin/nixlbench"
else
  bad "missing ${NIXLBENCH_PREFIX}/bin/nixlbench (run install-nixlbench.sh)"
fi

# gflags --help exits 1; treat crash (139) / missing binary as failure
set +e
nixlbench --help >/tmp/nixlbench-help.out 2>/tmp/nixlbench-help.err
help_ec=$?
set -e
if [[ "${help_ec}" -eq 139 ]] || ! grep -q 'NIXL Benchmark' /tmp/nixlbench-help.out /tmp/nixlbench-help.err 2>/dev/null; then
  bad "nixlbench --help failed (exit ${help_ec}; check LD_LIBRARY_PATH / grpc clash)"
else
  ok "nixlbench --help works (exit ${help_ec})"
fi


# 2. NIXL + EFA paths / libs
if [[ -d /opt/amazon/efa ]]; then
  ok "/opt/amazon/efa present"
else
  bad "/opt/amazon/efa missing (EFA installer libs not in image?)"
fi

if [[ -d /opt/ucx ]] || ls /opt/ucx/lib*/libucp.so* >/dev/null 2>&1; then
  ok "/opt/ucx present"
else
  # UCX may also be under /usr; warn soft
  if ldconfig -p 2>/dev/null | grep -q libucp; then
    ok "libucp visible via ldconfig"
  else
    bad "UCX libraries not found under /opt/ucx"
  fi
fi

LIBNIXL=""
for f in \
  "${NIXL_LINK_PREFIX}/lib64/libnixl.so" \
  /opt/vllm/lib/python3.12/site-packages/.nixl_cu12.mesonpy.libs/libnixl.so \
  /opt/vllm/lib64/python3.12/site-packages/.nixl_cu12.mesonpy.libs/libnixl.so \
  /usr/lib64/libnixl.so \
  /opt/nixl/lib64/libnixl.so
do
  if [[ -e "${f}" ]]; then LIBNIXL="${f}"; break; fi
done
if [[ -n "${LIBNIXL}" ]]; then
  ok "libnixl found: ${LIBNIXL}"
else
  bad "libnixl.so not found"
fi
if [[ -n "${NIXL_PLUGIN_DIR:-}" && -e "${NIXL_PLUGIN_DIR}/libplugin_LIBFABRIC.so" ]]; then
  ok "LIBFABRIC plugin: ${NIXL_PLUGIN_DIR}/libplugin_LIBFABRIC.so"
elif [[ -e "$(dirname "${LIBNIXL}")/plugins/libplugin_LIBFABRIC.so" ]]; then
  ok "LIBFABRIC plugin next to libnixl"
else
  bad "libplugin_LIBFABRIC.so not found"
fi

if command -v ldd >/dev/null 2>&1 && command -v nixlbench >/dev/null 2>&1; then
  if ldd "$(command -v nixlbench)" 2>&1 | grep -q 'not found'; then
    bad "nixlbench has unresolved shared libs:"
    ldd "$(command -v nixlbench)" 2>&1 | grep 'not found' || true
  else
    ok "nixlbench ldd has no missing libs"
  fi
fi

# 3. EFA devices via libfabric
export PATH="/opt/amazon/efa/bin:${PATH}"
EFA_COUNT=0
if command -v fi_info >/dev/null 2>&1; then
  EFA_COUNT="$(fi_info -p efa -t FI_EP_RDM 2>/dev/null | grep -c '^provider:' || true)"
  if [[ "${EFA_COUNT}" -ge "${EXPECT_EFA_MIN}" ]]; then
    ok "fi_info EFA RDM providers: ${EFA_COUNT} (min ${EXPECT_EFA_MIN})"
  else
    bad "fi_info EFA RDM providers: ${EFA_COUNT} (expected >= ${EXPECT_EFA_MIN})"
  fi
else
  bad "fi_info not found (expected under /opt/amazon/efa/bin)"
fi

if command -v ibv_devinfo >/dev/null 2>&1 || [[ -x /opt/amazon/efa/bin/ibv_devinfo ]]; then
  ok "ibv_devinfo available"
else
  # soft: not always packaged on PATH
  echo "  [WARN] ibv_devinfo not on PATH (optional)"
fi

# 4. GPUs
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_COUNT="$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${GPU_COUNT}" -ge "${EXPECT_GPUS}" ]]; then
    ok "nvidia-smi GPUs: ${GPU_COUNT} (expect ${EXPECT_GPUS})"
  else
    bad "nvidia-smi GPUs: ${GPU_COUNT} (expect ${EXPECT_GPUS})"
  fi
else
  bad "nvidia-smi not found"
fi

# 5. LIBFABRIC smoke (prefer nixl_cu12 wheel that ships the plugin)
if [[ "${SKIP_LIBFABRIC_SMOKE}" != "1" ]]; then
  PY=python3
  [[ -x /opt/vllm/bin/python3 ]] && PY=/opt/vllm/bin/python3
  if "${PY}" - <<'EOF'
import importlib
import os

plugin = os.environ.get("NIXL_PLUGIN_DIR", "")
os.environ.setdefault("NIXL_PLUGIN_DIR", plugin)

mod = None
for name in ("nixl_cu12._api", "nixl._api"):
    try:
        mod = importlib.import_module(name)
        break
    except ImportError:
        continue
if mod is None:
    raise SystemExit("no nixl python api")
agent = mod.nixl_agent("check-nixlbench", mod.nixl_agent_config(backends=["LIBFABRIC"]))
print("LIBFABRIC agent ok via", mod.__name__)
EOF
  then
    ok "NIXL LIBFABRIC Python agent smoke"
  else
    bad "NIXL LIBFABRIC Python agent smoke failed"
  fi
else
  echo "  [SKIP] LIBFABRIC Python smoke (SKIP_LIBFABRIC_SMOKE=1)"
fi

# 6. UCX readiness (informational + soft fail)
if command -v ucx_info >/dev/null 2>&1 || [[ -x /opt/ucx/bin/ucx_info ]]; then
  UCX_INFO="$(command -v ucx_info 2>/dev/null || echo /opt/ucx/bin/ucx_info)"
  if "${UCX_INFO}" -d >/dev/null 2>&1; then
    ok "ucx_info -d works"
  else
    echo "  [WARN] ucx_info -d returned non-zero (may still work with UCX_TLS=efa,...)"
  fi
else
  echo "  [WARN] ucx_info not found; UCX libs may still be usable via NIXL"
fi

# 7. UCCL (optional: CHECK_UCCL=1, or auto if plugin already staged)
UCCL_PLUGIN="${UCCL_P2P_PREFIX}/nixl-plugins/libplugin_UCCL.so"
if [[ "${CHECK_UCCL}" == "1" || -e "${UCCL_PLUGIN}" ]]; then
  echo "--- UCCL checks ---"
  # shellcheck disable=SC1091
  if [[ -f /usr/local/nixlbench/uccl-env.sh ]]; then
    set +u
    source /usr/local/nixlbench/uccl-env.sh
    set -u
    ok "uccl-env.sh sourced (NIXL_PLUGIN_DIR=${NIXL_PLUGIN_DIR})"
  else
    bad "uccl-env.sh missing"
  fi
  if [[ -e "${UCCL_P2P_PREFIX}/lib/libuccl_p2p.so" ]]; then
    ok "libuccl_p2p: ${UCCL_P2P_PREFIX}/lib/libuccl_p2p.so"
  else
    bad "libuccl_p2p missing under ${UCCL_P2P_PREFIX}/lib (run install-uccl-p2p.sh)"
  fi
  if [[ -e "${UCCL_PLUGIN}" ]]; then
    ok "UCCL plugin: ${UCCL_PLUGIN}"
  else
    bad "libplugin_UCCL.so missing at ${UCCL_PLUGIN}"
  fi
  echo "  UCCL_P2P_TRANSPORT=${UCCL_P2P_TRANSPORT:-<unset>}"
  if [[ "${UCCL_P2P_TRANSPORT:-}" != "efa" ]]; then
    echo "  [WARN] UCCL_P2P_TRANSPORT should be 'efa' for EKS EFA (got: ${UCCL_P2P_TRANSPORT:-<unset>})"
  fi
  if [[ -e "${UCCL_PLUGIN}" ]]; then
    PY=python3
    [[ -x /opt/vllm/bin/python3 ]] && PY=/opt/vllm/bin/python3
    export NIXL_PLUGIN_DIR="${UCCL_P2P_PREFIX}/nixl-plugins"
    export LD_LIBRARY_PATH="${UCCL_P2P_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
    export UCCL_P2P_TRANSPORT="${UCCL_P2P_TRANSPORT:-efa}"
    # UCCL agent starts accept threads that keep the process alive; use os._exit after success.
    if timeout 30 "${PY}" - <<'EOF'
import importlib
import os
import sys

os.environ.setdefault("UCCL_P2P_TRANSPORT", "efa")
mod = None
for name in ("nixl_cu13._api", "nixl._api", "nixl_cu12._api"):
    try:
        mod = importlib.import_module(name)
        break
    except ImportError:
        continue
if mod is None:
    raise SystemExit("no nixl python api")
agent = mod.nixl_agent("check-uccl", mod.nixl_agent_config(backends=["UCCL"]))
print("UCCL agent ok via", mod.__name__, "transport", os.environ.get("UCCL_P2P_TRANSPORT"))
sys.stdout.flush()
os._exit(0)
EOF
    then
      ok "NIXL UCCL Python agent smoke"
    else
      bad "NIXL UCCL Python agent smoke failed"
    fi
  fi
elif [[ "${CHECK_UCCL}" == "1" ]]; then
  bad "CHECK_UCCL=1 but UCCL not installed (run install-uccl-p2p.sh)"
fi

echo "=== summary: ${PASS} passed, ${FAIL} failed ==="
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
