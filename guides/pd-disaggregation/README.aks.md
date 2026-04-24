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

`just ready` waits for the inference extension pod using `app.kubernetes.io/name=gaie-${RELEASE_NAME_POSTFIX:-pd}-epp`, matching the `gaie-*` Helm release name in `helmfile.yaml.gotmpl`.

**Secrets on AKS** with [`ms-pd/values_aks.yaml`](./ms-pd/values_aks.yaml): use secret name **`hf-secret`** (key `HF_TOKEN`), which matches `just setup` in this Justfile.

**Tensor parallelism and replicas** (defaults match `values_aks.yaml`): export `PREFILL_TP`, `DECODE_TP`, `PREFILL_REPLICAS`, `DECODE_REPLICAS` before `just deploy-helm` / `just deploy` / `just start`, or run `just deploy-with-tp <prefill_tp> <decode_tp> <prefill_replicas> <decode_replicas>` (runs idempotent `just setup` then deploy; first-time safe). Helmfile passes these as `--set` overrides for the `ms-pd` release on `-e aks`.

**Gateway traffic from poker** requires `just apply-httproute` (or `just start` / `just deploy`, which include it). If `/v1/models` returns 404, apply the route or set `BENCHMARK_MODEL` when running `just benchmark`. For direct-to-decode benches, use `just benchmark_no_pd` inside the poker pod (see synced [`../../poker/Justfile.remote`](../../poker/Justfile.remote)).
