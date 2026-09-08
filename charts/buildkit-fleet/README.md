# buildkit-fleet Helm chart

Deploys a fleet of warm BuildKit shards: one StatefulSet per CPU architecture,
one cache disk per shard, mTLS via cert-manager, a per-shard admission cap and a
per-architecture HorizontalPodAutoscaler. The [setup-buildkit](../../actions/setup-buildkit)
action routes each repository to a stable shard.

Design rationale lives in [docs/architecture.md](../../docs/architecture.md) and
[docs/design-decisions.md](../../docs/design-decisions.md). Day-two procedures
are in [docs/operations.md](../../docs/operations.md).

## Requirements

- Kubernetes 1.27+
- [cert-manager](https://cert-manager.io) 1.12+ (or set `trust.enabled: false`
  and provide the Secrets yourself)
- A StorageClass with `allowVolumeExpansion: true` (any CSI driver)
- Nodes for each enabled architecture, ideally one shard per node
- No request right-sizing automation (VPA and similar) acting on the release
  namespace — it breaks Guaranteed QoS and the autoscaler's utilisation signal

## Install

```bash
helm install buildkit ./charts/buildkit-fleet \
  --namespace buildkit --create-namespace \
  --set trust.clientCertificate.namespaces='{actions-runner}' \
  --set networkPolicy.allowedNamespaces='{actions-runner}'
```

Start from one of the [examples](examples/):

| file | what it shows |
|---|---|
| `values-small.yaml` | amd64 only, 6 CPU / 24 GiB shards, for evaluation |
| `values-gke.yaml` | PD-SSD + Hyperdisk storage classes, node-pool pinning, a Docker Hub mirror |
| `values-datadog.yaml` | Datadog scraping and the in-flight-builds external metric |

## The knobs that matter

| value | default | why it is where it is |
|---|---|---|
| `architectures.<arch>.resources` | 28 CPU / 50 GiB | Requests must equal limits: Guaranteed QoS earns an exclusive cpuset and keeps HPA utilisation meaningful. Size for one shard per node. |
| `admissionCapPercent` | 80 | Build steps past 80% of the CPU limit queue inside BuildKit instead of time-slicing. Throughput is CPU-bound either way; queueing keeps latency and memory flat. |
| `architectures.<arch>.storage.size` | 300Gi | Warm cache per shard. Immutable on a live StatefulSet — see operations.md for the resize procedure. |
| `gc.reservedSpace` | 250 GiB | The size GC prunes down to. Leave 15–30% of the disk above it; GC is lazy. |
| `architectures.<arch>.autoscaling` | 2–4 | `min` is steady state, `max` is burst headroom. Past ~6 shards the tail carries little load, so put headroom in `max`, not `min`. |
| `autoscaling.cpuUtilization` | 85 | Primary signal. One saturated shard next to one idle shard reads 50%, so the client-side spill in `setup-buildkit` is what spreads load before the HPA can see it. |
| `autoscaling.externalMetric` | off | Adds "builds accepted per shard". Useful, but an unavailable external metric freezes scale-down. |
| `terminationGracePeriodSeconds` | 600 | buildkitd drains in-flight builds on SIGTERM. |

## What gets created

Per enabled architecture: StatefulSet, headless Service, HPA, PDB, server
Certificate (wildcard SAN, so scaling needs no re-issue), optional StorageClass.
Shared: buildkitd ConfigMap, load-probe ConfigMap, NetworkPolicy, and the trust
chain (self-signed ClusterIssuer → CA Certificate → CA ClusterIssuer) plus one
client Certificate per runner namespace.

## Uninstall

`helm uninstall` leaves the cache PVCs behind on purpose
(`persistentVolumeClaimRetentionPolicy: Retain`). Delete them by hand when you
are sure: `kubectl -n buildkit delete pvc -l app=buildkit`.
