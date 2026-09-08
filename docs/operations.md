# Operations

Day-two procedures for the fleet. Commands assume the chart is installed in the
`buildkit` namespace with the default `namePrefix`.

## Inventory

| object | name | notes |
|---|---|---|
| StatefulSet | `buildkit-<arch>` | `replicas` owned by the HPA; pods `buildkit-<arch>-<n>` |
| Service | `buildkit-<arch>` | headless; per-pod DNS `buildkit-<arch>-<n>.buildkit-<arch>` |
| PVC | `cache-buildkit-<arch>-<n>` | one per shard, retained on scale-in and on StatefulSet deletion |
| HPA | `buildkit-<arch>` | CPU ≥ 85% (and optionally accepted builds ≥ target) held 30 s → +1 shard/min; −1 shard/10 min after 15 min below |
| PDB | `buildkit-<arch>` | `maxUnavailable: 1` |
| ConfigMap | `buildkit-config` | `buildkitd.toml`: mirrors and GC |
| ConfigMap | `buildkit-load-probe` | sidecar scripts |
| Certificate | `buildkit-<arch>-server`, `buildkit-client` | server per arch; client per runner namespace |

## Health at a glance

```bash
kubectl -n buildkit get sts,pod,pvc,hpa
kubectl -n buildkit exec buildkit-amd64-0 -c buildkit -- buildctl debug workers
kubectl -n buildkit exec buildkit-amd64-0 -c load -- \
  sh -c 'wget -qO- http://127.0.0.1:8080/load'      # {"inflight":N,"cap":M,"full":false}
```

A shard is healthy when the pod is `2/2 Ready`, `buildctl debug workers` lists
one worker, and the HPA shows a numeric CPU target (not `<unknown>`).

## Cache disk

```bash
# Usage from inside the pod
kubectl -n buildkit exec buildkit-amd64-0 -c buildkit -- df -h /home/user/.local/share/buildkit
# What buildkitd thinks it is holding, per cache type
kubectl -n buildkit exec buildkit-amd64-0 -c buildkit -- buildctl du -v
```

`gc.reservedSpace` is the size GC converges on, **not a hard cap**. GC is lazy,
so usage will overshoot it between sweeps; the gap up to the disk size is the
margin that absorbs that. Keep 15–30% of the disk above the target. If `df`
approaches 100%, see *Disk full* below.

To prune now rather than waiting for the collector:

```bash
kubectl -n buildkit exec buildkit-amd64-0 -c buildkit -- buildctl prune                     # everything reclaimable
kubectl -n buildkit exec buildkit-amd64-0 -c buildkit -- buildctl prune --keep-duration 168h
```

## Growing the cache disk

`volumeClaimTemplates` is **immutable on a live StatefulSet**. Changing
`architectures.<arch>.storage.size` and upgrading fails with
`updates to statefulset spec for fields other than 'replicas', 'ordinals',
'template', ... are forbidden` — and because the patch is atomic, any other
change in the same upgrade (a memory resize, say) is rejected with it.

Do it in this order. Both steps are online; PVCs attached to running pods resize
live, detached ones (retained from an earlier scale-out) complete on next mount.

**1. Expand the existing PVCs** (the StorageClass must have `allowVolumeExpansion: true`):

```bash
for pvc in $(kubectl -n buildkit get pvc -o name -l app=buildkit); do
  kubectl -n buildkit patch "$pvc" -p '{"spec":{"resources":{"requests":{"storage":"300Gi"}}}}'
done
```

Do this **before** raising `gc.reservedSpace`. A GC target larger than the disk
can never fire, and buildkitd reads its config only at start-up — so a shard
that restarts after the ConfigMap changed but before its disk grew has no size
backstop at all.

**2. Recreate the StatefulSet objects with the new template.** Pods and PVCs
survive; the new object adopts the running pods through the label selector:

```bash
kubectl -n buildkit delete sts buildkit-amd64 buildkit-arm64 --cascade=orphan
helm upgrade buildkit ./charts/buildkit-fleet -n buildkit -f values.yaml
```

**Watch out:** the manifest omits `spec.replicas` because the HPA owns it. On a
*freshly created* StatefulSet the API defaults it to **1**, so the moment the
object exists it starts draining ordinal 1 (with the full 600 s grace) before
the HPA pushes it back to `minReplicas`. Avoid the churn by rendering with
replicas set for this one apply:

```bash
helm template buildkit ./charts/buildkit-fleet -n buildkit -f values.yaml \
  | yq '(select(.kind == "StatefulSet") | .spec.replicas) = 2' \
  | kubectl apply -f -
```

Any template change (image, resources, probes) rolls both shards, so do this
when `inflight` is 0 — see *Health at a glance*.

## Disk full

Symptoms: builds fail with `no space left on device`; `df` inside the pod near
100%. Causes in likely order: GC target too close to (or above) the disk size;
a burst of very large images between sweeps; a shard whose disk did not grow
when the template did.

1. `buildctl prune` on the affected shard for immediate relief.
2. Check `gc.reservedSpace` against the *actual* PVC capacity
   (`kubectl get pvc`), not the template.
3. Grow the disk (above) or lower the target.

## Scaling

**Horizontal.** Adjust `architectures.<arch>.autoscaling.minReplicas` /
`maxReplicas`. `min` is steady state, `max` is burst headroom. Past roughly six
shards each additional one carries only a few percent of traffic, so put
headroom in `max`, not `min`. A repository pins to one shard, so more shards
spread *repositories*, not one hot repository's load — for that, widen the
action's `routing-key` or size the shard up.

**Vertical.** Change `resources` (requests must stay equal to limits). The
admission cap follows the CPU limit automatically. Memory grows with concurrent
build steps, so watch peak usage against the limit if you raise
`admissionCapPercent`.

**Time to a new shard.** With a node already available and the image cached:
metric latency plus the 30 s window plus a few seconds of pod start — a minute
or two. When a node must be created, add node provisioning and an image pull,
which dominate. Pin an architecture to a dedicated node pool (`nodeSelector` /
`affinity`) if you want that path to be the predictable one; without a pin,
shards bin-pack onto whatever tolerated node has room.

## Rollouts and drains

buildkitd drains in-flight builds on SIGTERM with a 600 s grace period. A
rollout while builds are active is slow by design; the PDB lets a node drain
take one shard at a time. Check `inflight` on each shard first if you want it
fast.

## The external metric is `<unknown>`

If `kubectl get hpa` shows `<unknown>/22` on the external metric and events say
`FailedGetExternalMetric`, the HPA will still scale **up** on CPU but will not
scale **down** at all until the metric returns. Typical causes:

- the metrics provider was disabled or redeployed without the external-metrics
  API (check `kubectl get apiservice v1beta1.external.metrics.k8s.io`: it must be
  `Available=True`; `connection refused` on its endpoint means the provider pod
  is not serving it);
- nothing is scraping the load-probe sidecar on some nodes, most often because
  the metrics agent DaemonSet lacks a toleration for the shard nodes' taints;
- the query returns no series (a renamed metric, a stale rollup).

Until fixed, either accept a fleet pinned at its current size or set
`autoscaling.externalMetric.enabled: false` and upgrade.

## Certificates

Rotate a leaf by deleting its Secret; cert-manager re-issues it:

```bash
kubectl -n buildkit delete secret buildkit-amd64-server-tls   # shard picks it up on restart
kubectl -n actions-runner delete secret buildkit-client-tls   # new runner pods get the new cert
```

Re-signing the CA invalidates every leaf; do it as a coordinated rollout.

## Force-removing a stuck shard

```bash
kubectl -n buildkit delete pod buildkit-amd64-1 --grace-period=0 --force
```

The StatefulSet recreates it on the same PVC. If the node itself is gone, the
disk detach/reattach can take several minutes; builds routed to that ordinal
fail over to the next-ranked shard in the meantime.

## Uninstall

`helm uninstall` leaves the cache PVCs behind on purpose. Remove them when you
are sure: `kubectl -n buildkit delete pvc -l app=buildkit`.
