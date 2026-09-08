# Architecture

## The problem with build caches in CI

BuildKit has three caches, and the fast one is the one CI usually throws away.

| cache | answers | lives |
|---|---|---|
| layer cache | "should this step run again?" | in the worker's content store |
| `RUN --mount=type=cache` | "while running, what can I reuse?" — pip/npm/go/apt scratch | on the worker's disk, never in a layer |
| registry cache (`type=registry`) | "can another worker reuse my keys?" | in the registry, carries layer *results*, never mounts |

A stateless worker — the `docker-container` driver buildx creates fresh for
every job — can import the registry cache and correctly mark a step `CACHED`.
But `CACHED` means the *key* matched, not that the *bytes* are present. To build
the next layer on top it still has to pull and extract every cached parent layer
into its snapshotter. Take an image with a multi-gigabyte dependency layer and
a one-line source change on top of it:

```
# stateless worker, --cache-from type=registry
#11 [5/6] RUN pip install ...  CACHED   <- key matched, RUN skipped
#11 sha256:...  0B / N GB  ...          <- pulls the whole layer anyway
#11 extracting sha256:...  done         <- and unpacks it
#11 DONE <minutes>

# same change on a warm, persistent worker:
#11 [5/6] RUN pip install ...  CACHED
#11 DONE 0.0s                           <- bytes already on local disk
```

That pull-and-extract is a network-materialisation tax paid on every build where
nothing meaningful changed, and it scales with the size of the cached layers,
not with the size of the change. It is the reason a warm worker beats registry transport, and
it is why everything below is organised around **cache locality**.

## Constraints that shape the design

1. **BuildKit is single-writer per cache.** Its content store plus BoltDB
   metadata cannot be shared between two daemons; they corrupt each other. So a
   ReadWriteOnce disk per daemon, and exactly one daemon per disk.
2. **Therefore HA and scale mean N independent daemons**, each with its own
   cache — never replicas over one volume.
3. **Locality only pays if routing is sticky.** Load-balancing builds across N
   independent caches would land most of them cold.

## Topology

```
ns: buildkit
  StatefulSet buildkit-amd64  (N shards)     StatefulSet buildkit-arm64  (N shards)
    buildkit-amd64-0 ── PVC cache-...-0        buildkit-arm64-0 ── PVC cache-...-0
    buildkit-amd64-1 ── PVC cache-...-1        buildkit-arm64-1 ── PVC cache-...-1
    ...                                        ...
    headless Service buildkit-amd64            headless Service buildkit-arm64
      buildkit-amd64-<n>.buildkit-amd64.<ns>.svc.cluster.local

ns: <runners>
  ephemeral runner pod, client cert at /certs
    setup-buildkit -> one buildx builder: node-amd64 + node-arm64 (remote driver, mTLS)
```

**One StatefulSet per architecture.** Stable identities (`-0`, `-1`, …), one
PVC per ordinal via `volumeClaimTemplates`, `podManagementPolicy: Parallel`
because shards are independent, and `persistentVolumeClaimRetentionPolicy:
Retain` so a shard the autoscaler removes comes back warm.

**Headless Service with per-pod DNS.** Clients address a specific shard by
name. `publishNotReadyAddresses: true` keeps a busy-but-NotReady shard
resolvable so a probe flap does not divert its repositories to a cold shard;
mTLS still gates actual use.

**mTLS via cert-manager.** A private CA, one server certificate per
architecture with a wildcard SAN (`*.buildkit-amd64.<ns>.svc.cluster.local`) so
scaling needs no re-issue, and one client certificate issued into each runner
namespace.

**No `spec.replicas` in the manifest.** The HPA owns it. (One consequence for
operators: a freshly *created* StatefulSet object defaults to one replica — see
operations.md.)

## Routing: rendezvous hashing

For a key — by default the repository name — and the live shard set
`{0..N-1}`, compute `weight(ordinal) = sha256("<key>:<ordinal>")[:16]` and rank
shards by weight, highest first.

- Rank 1 is the **home shard**. Same key, same ordinal, on every architecture,
  so a multi-arch build has matching locality on both.
- Ranks 2..N are the **spill and failover order**, stable across calls.
- Adding or removing a shard moves only keys whose top-weighted shard changed
  — about 1/N of them. Modulo hashing would reshuffle almost all.

**Shard discovery is DNS, not the Kubernetes API.** The action walks
`buildkit-<arch>-0`, `-1`, … until two consecutive names fail to resolve.
Ordinals are contiguous, and a pod being recreated has no record, so tolerating
one gap keeps a rolling update from hiding every shard above it. The runner
needs zero RBAC. A static fallback count is honoured only when DNS returns
nothing at all.

**The hot-repository ceiling.** A repository pins to one shard, so the hottest
shard's share of fleet load converges on the busiest repository's share of
builds, for *any* shard count. If one repository is half your builds, the hottest
shard carries about half the load whether you run four shards or sixteen. Shard
count spreads repositories, not load. The fixes are a wider routing key (`repository/image`)
or a bigger shard; the action exposes `routing-key` for the first.

## Capacity control: three layers

Capacity is core-seconds, not concurrency. A compile-heavy build parallelises
across every core it is given, so a handful of concurrent cold builds saturate a
shard well below one build per core; past that, concurrency only time-slices the
CPU. Latency then grows linearly with concurrency while throughput stays flat.

1. **Admission cap (per shard).** `buildkitd --oci-max-parallelism` set to 80%
   of the CPU limit, derived from the Downward API so a resize keeps the ratio.
   Steps past the cap queue inside BuildKit instead of time-slicing. Throughput
   is unchanged; latency and memory stay flat. Cache hits never take a slot.

2. **Bounded-load spill (client side).** Each shard runs a small sidecar that
   answers `GET :8080/load` with `{"inflight", "cap", "full"}`, where
   `inflight` is the count of established gRPC connections on :1234 — one per
   accepted build, running or queued. `setup-buildkit` walks the rank order; at
   a shard reporting `full` it waits for a slot (15 s at the home shard, halving
   at each later rank, ~26 s bounded) and then moves on. Cold on the new shard,
   but a cold build beats a queue. When every shard is full it queues on the
   home shard, where the cache is. The probe **fails open**: no answer means
   "not full", so a fleet without the sidecar keeps plain routing.

3. **Per-architecture HPA (fleet).** CPU utilisation at 85% is the primary
   signal; a 30 s stabilisation window is the practical floor (the window keeps
   the *lowest* recommendation seen inside it). Optionally, a second metric —
   builds accepted per shard, from the same sidecar via your metrics pipeline —
   covers what CPU cannot see: a shard blocked on a slow registry reads ~0% CPU
   while still holding every build it accepted. Scale-out is one shard per
   minute; scale-in one per ten minutes after fifteen minutes below target.

Layers 1 and 2 absorb bursts; the HPA follows the daily curve. From saturation
to a new shard taking builds is metric latency plus the window plus pod start
when a node with the image already exists — a minute or two — and considerably
longer when a node has to be provisioned and the image pulled first.

Two properties matter when you read a dashboard. The HPA divides total usage by
total requests, so one saturated shard beside one idle shard reads 50% — the
metric only becomes meaningful once spill has spread the load, which is why
spill sits below the HPA. And while an external metric is *unavailable*,
Kubernetes still scales up on the metrics it has but refuses to scale down at
all; the fleet holds its size until the metric returns.

## Garbage collection

BuildKit prunes continuously, in-process. The policy is TTL-first with a size
backstop: 48 h for frontends and git checkouts, 7 days for cache mounts, step
results and local sources, and `reservedSpace` — the size GC converges on —
as a catch-all. It is a target, not a hard cap; leave 15–30% of the disk above
it.

## Multi-architecture

`setup-buildkit` joins one shard per architecture into a single buildx builder
using the `remote` driver. buildx routes each platform in a build to the node of
that architecture natively — no QEMU, no emulation penalty. The one consumer
gotcha: `platforms` on the setup action configures the *builder*; `platforms`
on `build-push-action` drives the *build*. Set both.

## What deliberately is not here

- **No `kubernetes` buildx driver.** It would need RBAC in the runner namespace
  and would create and destroy a builder pod per build, discarding the warm
  cache that is the whole point.
- **No cloud credentials on the shards.** Registry pull and push credentials are
  resolved by the runner and arrive per session in the gRPC request.
- **No GitHub Actions cache (`type=gha`) for layer caching.** It duplicates the
  shard's disk cache, and under a large matrix the exporters can spend most of
  the build blocked on the cache service while the shards sit idle.
