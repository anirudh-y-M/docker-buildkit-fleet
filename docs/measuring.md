# Measuring your fleet

The defaults in `values.yaml` are starting points. Every one of them should be
confirmed or corrected against your own workload before you rely on it. This
page is the method: what to measure, how, and which knob each measurement
informs.

## 1. The cold-to-warm ratio

**Informs:** whether a warm fleet is worth running at all for your images.

Pick a representative build and run it twice on the fleet from the same commit:
once with the shard's cache empty (a fresh ordinal, or after `buildctl prune
--all`), once immediately after. Record the per-step times buildx prints and
the whole-job wall time.

Then run the same pair on a stateless `docker-container` builder with
`--cache-from type=registry`. The interesting cell is the warm registry-cache
build: steps will show `CACHED`, and the time next to them is the pull-and-extract
tax the fleet removes. If that number is small for your images, the fleet buys
you little; if it is minutes, it buys you those minutes on every build.

## 2. The per-shard envelope

**Informs:** `resources`, `admissionCapPercent`, and the node size.

Drive one shard with a closed loop of *k* concurrent cold builds, for
*k* = 1, 2, 4, 8, … and hold each level for a few minutes. Watch three things
from inside the cluster rather than through a metrics vendor's rollups:

| watch | how | what it tells you |
|---|---|---|
| shard CPU vs. limit | `kubectl top pod`, or `container_cpu_usage_seconds_total` | the *k* at which CPU pegs is your real per-shard concurrency; the cap should sit near it |
| shard memory vs. limit | same | peak working set sets the memory limit; leave headroom, since memory is what kills a shard and CPU only slows it |
| per-build latency vs. *k* | the closed loop's own timing | once CPU is pegged, latency grows linearly with *k* and throughput is flat — everything past that point should queue, not run |

Compile-heavy workloads saturate a shard at a small *k*; download- or
IO-heavy ones at a much larger one. That difference is why `admissionCapPercent`
is a value.

Two artefacts to watch for: CFS throttling that appears only when requests and
limits differ (keep them equal), and single-sample CPU readings above the limit
from some agents — average over a minute before believing a peak.

## 3. Load distribution across shards

**Informs:** `autoscaling.minReplicas` / `maxReplicas`, and whether you need a
wider `routing-key`.

Take a few weeks of build counts per repository from your CI system and run them
through the routing function to see how load would spread over *N* shards:

```bash
source actions/setup-buildkit/shard.sh
while read -r repo count; do
  echo "$(hrw_ranked "$repo" "$N" | head -1) $count"
done < builds-per-repo.txt | awk '{s[$1]+=$2; t+=$2} END {for (k in s) printf "shard %s  %.0f%%\n", k, 100*s[k]/t}'
```

Repeat for *N* = 1, 2, 4, 6, 8, 12. Three things fall out:

- **The hottest shard's share** converges on your busiest repository's share of
  builds. If one repository dominates, no shard count fixes it; give it a wider
  routing key (repository plus image) or a bigger shard.
- **Where the curve flattens** is your `minReplicas`. Past that point each extra
  shard carries only a few percent, so burst headroom belongs in `maxReplicas`.
- **Empty shards** at high *N* are wasted disks; keep `maxReplicas` below the
  point where they appear.

## 4. Scale-out latency

**Informs:** `autoscaling.behavior` and whether an architecture needs a
dedicated node pool.

From pod conditions after a scale-out or a rollout:

```bash
kubectl -n buildkit get pod buildkit-amd64-2 -o json \
  | jq -r '.metadata.creationTimestamp, (.status.conditions[] | "\(.type) \(.lastTransitionTime)")'
```

Break the total into: metric latency (your pipeline), the HPA stabilisation
window, node provisioning if any, image pull if the node is fresh, and container
start to `Ready`. The last is a few seconds with the default readiness probe;
node provisioning and image pull will dominate whenever they happen. If you want
the fast path to be the common one, keep the image cached on a warm pool.

## 5. Garbage-collection headroom

**Informs:** `gc.reservedSpace` against `storage.size`.

Over a week, sample `df` inside each shard and `buildctl du -v`. GC is lazy and
converges on `reservedSpace` rather than enforcing it, so the overshoot you
observe between sweeps is the margin you need between the target and the disk
size. Start with 15–30% and tighten only with data.

## 6. What the registry and GitHub caches cost you

**Informs:** whether to keep `cache-to type=registry` on release builds, and
whether to remove `type=gha`.

Compare a build's step timeline with and without each export. Cache *export*
happens after the image is pushed and is pure network cost when the shard's own
disk is already warm; on a busy fleet it can dominate the job while the shards
sit idle. Keep the registry export where it pays for itself (cold-shard
recovery after a failover), and drop `gha` on the fleet — it duplicates the disk
cache.

## Reporting

If you contribute a default change, include: the workload (what the builds do),
the shard spec, the *k* sweep or matrix you ran, and the numbers before and
after. The point is not that your numbers match anyone else's — it is that the
next reader can tell whether their workload looks like yours.
