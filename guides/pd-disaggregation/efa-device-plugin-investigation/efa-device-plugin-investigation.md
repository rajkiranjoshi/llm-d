# AWS EFA Kubernetes Device Plugin: Topology-Aware Allocation Investigation

## Is the EFA Device Plugin Open Source?

**Partially.** The deployment artifacts are open source, but the plugin binary itself is closed-source.

| Component | Open Source | Location |
| --- | --- | --- |
| Helm chart | Yes | [aws/eks-charts](https://github.com/aws/eks-charts/tree/master/stable/aws-efa-k8s-device-plugin) |
| Container image (Go binary) | **No** | `602401143452.dkr.ecr.us-west-2.amazonaws.com/eks/aws-efa-k8s-device-plugin` |
| EFA kernel driver | Yes | [amzn/amzn-drivers](https://github.com/amzn/amzn-drivers) (kernel/linux/efa) |
| EFA DRA driver (DRANET, successor) | Yes | [kubernetes-sigs/dranet](https://github.com/kubernetes-sigs/dranet) |

The Go source code for the `aws-efa-k8s-device-plugin` binary is not publicly available. The Helm chart is open source but only contains Kubernetes manifests, not application logic. The newer DRA-based replacement (DRANET) is fully open source under kubernetes-sigs.

## How It Likely Integrates with Stock Kubernetes Kubelet

> **Note:** Since the plugin binary is closed-source, the mechanism described below is **inferred** from observed log output, the public Kubernetes Device Plugin API, and the kubelet source code. The actual implementation may differ.

The EFA device plugin uses the standard [Kubernetes Device Plugin API](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/) (gRPC v1beta1). No kubelet patches appear to be required. Based on our investigation, the integration likely involves three kubelet mechanisms:

### 1. Device Registration and Advertisement

The plugin runs as a privileged DaemonSet. On startup it likely:
1. Scans `/dev/infiniband/` on the host for EFA uverbs devices
2. Registers with the kubelet via the Unix socket at `/var/lib/kubelet/device-plugins/kubelet.sock`
3. Advertises discovered EFA devices as `vpc.amazonaws.com/efa` extended resources via `ListAndWatch`

Each EFA device appears to be registered with its RDMA device name (e.g., `rdmap79s0`) as the device ID.

### 2. NUMA Topology Hints (Coarse-Grained Alignment)

The Device Plugin API allows plugins to report `TopologyInfo` with NUMA node affinity when registering devices via `ListAndWatch`:

```protobuf
message Device {
    string ID = 1;
    string health = 2;
    TopologyInfo topology = 3;  // NUMA node(s) for this device
}
```

The kubelet's **Topology Manager** collects these NUMA hints from all device plugins (both NVIDIA GPU plugin and EFA plugin) and ensures co-located resources come from the same NUMA node(s). Our test results (GPUs consistently packed within a single NUMA node for counts 1-4) are consistent with this mechanism being active. On a p5.48xlarge, this would narrow candidates to the same NUMA node (0 or 1), each hosting 4 GPUs and 16 EFA NICs.

### 3. Kubelet Checkpoint File (Inferred: Fine-Grained PCIe Alignment)

The kubelet maintains a checkpoint file at `/var/lib/kubelet/device-plugins/kubelet_internal_checkpoint` that records which specific devices are allocated to which pods. Based on the plugin's log output, we believe the EFA plugin reads this checkpoint to achieve **PCIe switch-level** alignment with GPUs. The inferred flow:

1. Kubelet's `allocateContainerResources()` iterates over a container's resource limits and calls each device plugin's `Allocate` sequentially
2. After each successful `Allocate` call, the kubelet writes the allocation to the checkpoint file
3. When the EFA plugin's `Allocate` is called, it likely reads the checkpoint file to discover which GPU device IDs were allocated to the same pod
4. The EFA plugin maps those GPU UUIDs to PCIe bus addresses via sysfs
5. It then selects EFA devices that share the same PCIe switch as the allocated GPUs

Observed EFA plugin log output supporting this inference (p5.48xlarge, requesting 1 GPU + 4 EFA NICs):

```
GPUs allocated from context: [GPU-fbac74c3-799b-9861-d5c5-3d7b387b36c4]
Calling topology.PickClosestEFAs with devices: [GPU-fbac74c3-...], candidates: [...], needed: 4
Picking 4 EFAs from 32 candidates for 1 GPU devices
Topology returned 4 EFAs: [rdmap79s0 rdmap80s0 rdmap81s0 rdmap82s0]
```

The "GPUs allocated from context" line indicates the plugin is obtaining GPU allocation state from somewhere — the kubelet checkpoint file is the most likely source, given the plugin runs privileged with host path access to `/var/lib/kubelet/device-plugins/`. However, it could also be using another mechanism (e.g., querying the kubelet's `PodResources` gRPC API, or reading NVIDIA device plugin state directly).

## Inferred Two-Level Topology Alignment

Based on observed behavior and public API documentation, we believe the alignment works in two levels:

```
                   Kubernetes Topology Manager
                   ┌─────────────────────────┐
                   │   NUMA-level alignment   │
                   │  (TopologyInfo hints)    │
                   └──────────┬──────────────┘
                              │
                   ┌──────────▼──────────────┐
                   │ EFA Plugin's Allocate()  │
                   │                          │
                   │  1. Read GPU allocation  │
                   │     (checkpoint or       │
                   │      PodResources API?)  │
                   │  2. Find GPU PCIe addrs  │
                   │  3. PickClosestEFAs()    │
                   │     by PCIe switch       │
                   └──────────────────────────┘
                   PCIe switch-level alignment
```

**Level 1 — NUMA (Topology Manager):** Both plugins report NUMA affinity. The Topology Manager constrains allocation to devices on the same NUMA node. This would narrow from 32 EFA NICs to 16 (on p5.48xlarge with 2 NUMA nodes).

**Level 2 — PCIe switch (EFA plugin internal):** Within the NUMA-aligned set, the EFA plugin appears to read GPU allocation state, resolve their PCIe addresses, and pick EFA NICs on the same PCIe switch. This narrows from 16 to exactly 4 (each PCIe switch has 1 GPU + 4 EFA NICs on p5.48xlarge).

## Verified Behavior on p5.48xlarge (Legacy Device Plugin)

Tested on EKS with EKS-optimized AL2023 AMI, using the legacy NVIDIA device plugin + EFA device plugin (not DRA):

| GPUs | EFA NICs | PCIe Aligned | NUMA Packing |
| --- | --- | --- | --- |
| 1 | 4 | Yes (1/1) | Single NUMA |
| 2 | 8 | Yes (2/2) | Single NUMA |
| 3 | 12 | Yes (3/3) | Single NUMA |
| 4 | 16 | Yes (4/4) | Single NUMA |
| 5 | 20 | Yes (5/5) | Both (4+1) |
| 6 | 24 | Yes (6/6) | Both (4+2) |
| 7 | 28 | Yes (7/7) | Both (4+3) |
| 8 | 32 | Yes (8/8) | Both (4+4) |

The EFA device plugin correctly selects PCIe-aligned EFA NICs for every GPU count, with NUMA-packed GPU allocation for counts that fit in a single NUMA node (1-4).

## Important Caveats

### Ordering Dependency

The kubelet iterates over `container.Resources.Limits` (a Go map) to call each plugin's `Allocate`. Go map iteration order is non-deterministic. If the EFA plugin reads GPU state from the checkpoint, it requires the GPU allocation to happen **before** the EFA allocation so the checkpoint contains GPU data.

AWS states: *"Topology-aligned allocation of NVIDIA GPUs or Neuron devices with EFA interfaces happens automatically when using the EKS-optimized AL2023 accelerated AMIs."* This may indicate that the AMI's kubelet has deterministic ordering, that the EFA plugin handles the race gracefully (e.g., falling back to NUMA-only alignment if no GPU data is available yet), or that an entirely different coordination mechanism is used.

### MOFED Conflict

Starting with NVIDIA `k8s-device-plugin` v0.19.0, the `--mofed-enabled` flag defaults to `true`, causing the NVIDIA plugin to mount **all** `/dev/infiniband/uverbs*` devices into GPU containers. This conflicts with the EFA plugin, which manages EFA device allocation via those same uverbs devices. When using both plugins together, MOFED must be explicitly disabled on the NVIDIA plugin.


## Successor: EFA DRA Driver (DRANET)

> **Note:** We have not tested the DRA-based approach. The information below is from AWS documentation and the DRANET project.

As of May 2026, AWS recommends the [EFA DRA driver (DRANET)](https://github.com/kubernetes-sigs/dranet) for new deployments on K8s 1.34+. This uses the newer [Dynamic Resource Allocation (DRA)](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/) API instead of the legacy device plugin API.

Key advantages over the device plugin approach:

| Feature | Device Plugin | DRA (DRANET) |
| --- | --- | --- |
| Source code | Closed-source binary | Fully open source ([kubernetes-sigs/dranet](https://github.com/kubernetes-sigs/dranet)) |
| Topology alignment | Implicit (inferred: checkpoint reading or PodResources API) | Explicit (`resource.kubernetes.io/pcieRoot` attribute + CEL constraints) |
| Cross-plugin coordination | Opaque internal mechanism (likely kubelet checkpoint or PodResources API) | Via `matchAttribute` in `ResourceClaimTemplate` (declarative) |
| Device sharing between pods | Not supported | Supported via `ResourceClaim` |
| Works on non-EKS AMIs | Only on EKS-optimized AL2023 | Yes (Bottlerocket, custom AMIs) |

With DRA, both the NVIDIA GPU DRA driver and DRANET publish the `resource.kubernetes.io/pcieRoot` attribute. A `ResourceClaimTemplate` can use a CEL constraint to co-locate a GPU and an EFA adapter on the same PCIe root:

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: gpu-efa-aligned
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          count: 1
      - name: efa
        exactly:
          deviceClassName: efa.networking.k8s.aws
          count: 1
      constraints:
      - requests: [gpu, efa]
        matchAttribute: resource.kubernetes.io/pcieRoot
```

This is a cleaner, fully declarative approach with no hidden checkpoint-reading or ordering dependencies.
