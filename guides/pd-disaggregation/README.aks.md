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

**UCX NIC selection:** The default RHAII image (`rhaii/vllm-cuda-rhel9:3.4.0`) does not include per-GPU NIC selection. Helmfile installs the **`vllm-ucx-hotfix-<postfix>`** chart ([ms-pd/charts/vllm-ucx-multiproc-hotfix](./ms-pd/charts/vllm-ucx-multiproc-hotfix/README.md)) as a ConfigMap overlay that patches 5 existing vLLM files and adds `vllm_net_devices.py` (from [vllm-project/vllm#42083](https://github.com/vllm-project/vllm/pull/42083)). Mount paths in [values_aks.yaml](./ms-pd/values_aks.yaml) use YAML anchors (`x-vllm-hotfix-mounts`) defined once at the top. The flag **`aksUcxHotfixChart`** in [helmfile.yaml.gotmpl](./helmfile.yaml.gotmpl) controls installation (default: `true`). If the vLLM image already includes NIC selection in-tree (e.g. a custom `llm-d-cuda` build), set it to `false` and remove the ConfigMap volumeMounts. PD stacks here are **TP-only per pod**; **`EngineCore_DP0`** in logs does not imply multi–data-parallel inside the engine.

**Tensor parallelism and replicas** (defaults match `values_aks.yaml`): export `PREFILL_TP`, `DECODE_TP`, `PREFILL_REPLICAS`, `DECODE_REPLICAS` before `just deploy-helm` / `just deploy` / `just start`, or run `just deploy-with-tp <prefill_tp> <decode_tp> <prefill_replicas> <decode_replicas>` (runs idempotent `just setup` then deploy; first-time safe). Helmfile passes these as `--set` overrides for the `ms-pd` release on `-e aks`.

**Gateway traffic from poker** requires `just apply-httproute` (or `just start` / `just deploy`, which include it). If `/v1/models` returns 404, apply the route or set `BENCHMARK_MODEL` when running `just benchmark`. For direct-to-decode benches, use `just benchmark_no_pd` inside the poker pod (see synced [`../../poker/Justfile.remote`](../../poker/Justfile.remote)).
