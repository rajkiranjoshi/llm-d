# AKS: P/D disaggregation with `just`

Supplement for **Azure Kubernetes Service (AKS)** using `helmfile -e aks` and the [`Justfile`](./Justfile) in this directory. General install steps and architecture are in the main [README.md](./README.md).

From the repo root, use either `cd guides/pd-disaggregation` or pass `--working-directory` so paths resolve correctly:

```bash
cd guides/pd-disaggregation
cp .env.example .env   # optional: set NAMESPACE, HF_TOKEN, optional PREFILL_TP / DECODE_TP / *_REPLICAS
just deploy-with-tp 8 8 1 1   # idempotent setup + helm -e aks + HTTPRoute (tune four numbers); or `just start` for defaults
just ready && just status
just start-poker && just poke   # optional benchmarking pod; in-pod: just benchmark …
just stop                # P/D only: helmfile destroy -e aks + delete HTTPRoute (poker: `just stop-poker`)
just grafana             # port-forward cluster Grafana → http://localhost:3000 (ns llm-d-monitoring)
```

`just ready` waits for the inference extension (EPP) pod using `inferencepool=gaie-${RELEASE_NAME_POSTFIX:-pd}-epp` (the label on the **pod** from the gateway-api-inference-extension chart; `app.kubernetes.io/name` is only on the Deployment). It polls until decode, prefill, and EPP pods exist, then waits for **Ready**.

**Secrets on AKS** with [`ms-pd/values_aks.yaml`](./ms-pd/values_aks.yaml): use secret name **`hf-secret`** (key `HF_TOKEN`), which matches `just setup` in this Justfile.

**UCX:** On `-e aks`, helmfile installs **`vllm-ucx-hotfix-<postfix>`** (chart [ms-pd/charts/vllm-ucx-multiproc-hotfix](./ms-pd/charts/vllm-ucx-multiproc-hotfix)) → ConfigMap **`vllm-ucx-multiproc-hotfix`**. Helmfile sets **`usePcieGpuNicMapping: true`** so the ConfigMap embeds **`multiproc_executor-pcie.py`** as **`multiproc_executor.py`**; [values_aks.yaml](./ms-pd/values_aks.yaml) mounts it and sets **`VLLM_GPU_NIC_PCIE_MAPPING`** on decode/prefill (see chart README). For **`mlx5_<rank>:1`** without PCIe mapping, set **`usePcieGpuNicMapping: false`** in helmfile and **`VLLM_UCX_NET_DEVICES_PER_RANK=1`** on the workload. `helmfile destroy` removes the ConfigMap with that release. PD stacks here are **TP-only per pod**; **`EngineCore_DP0`** in logs does not imply multi–data-parallel inside the engine.

Optional validation pod: [ms-pd/ucx-hotfix-test/README.md](./ms-pd/ucx-hotfix-test/README.md).

**Tensor parallelism and replicas** (defaults match `values_aks.yaml`): export `PREFILL_TP`, `DECODE_TP`, `PREFILL_REPLICAS`, `DECODE_REPLICAS` before `just deploy-helm` / `just deploy` / `just start`, or run `just deploy-with-tp <prefill_tp> <decode_tp> <prefill_replicas> <decode_replicas>` (runs idempotent `just setup` then deploy; first-time safe). Helmfile passes these as `--set` overrides for the `ms-pd` release on `-e aks`.

**Gateway traffic from poker** requires `just apply-httproute` (or `just start` / `just deploy`, which include it). If `/v1/models` returns 404, apply the route or set `BENCHMARK_MODEL` when running `just benchmark`. For direct-to-decode benches, use `just benchmark_no_pd` inside the poker pod (see synced [`../../poker/Justfile.remote`](../../poker/Justfile.remote)).
