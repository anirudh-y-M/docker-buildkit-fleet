# Design decisions

Each decision is recorded with the reason it was taken and the cost accepted.
They are in dependency order: later ones fall out of earlier ones.

## 1. A StatefulSet of independent shards per architecture, not replicas of one builder

**Because** BuildKit is single-writer per cache: an RWO disk plus BoltDB metadata
means exactly one daemon may mount each cache. Scale and HA therefore mean N
daemons, each with its own disk.

**Cost:** a new shard is cold until traffic hashes to it. Losing a shard
degrades ~1/N of repositories to registry-cache speed rather than taking the
architecture down.

## 2. Headless Service with per-pod DNS

**Because** clients need stable per-shard addressing, and the client can
discover the live shard set by walking ordinals — no Kubernetes API call and no
RBAC on the runner.

**Cost:** discovery is a per-name DNS walk, since the Service record itself
carries no ordinals.

## 3. Rendezvous hash of the repository, same ordinal on both architectures

**Because** each repository gets a warm home, and one hash serves both
architectures so a multi-arch build has matching locality on each. Changing the
shard count remaps only ~1/N of repositories, against nearly all of them for
modulo.

**Cost:** a dominant repository pins to one shard, so the hottest shard's share of
fleet load converges on that repository's share of builds for any shard count.
The escape hatch is a wider routing key.

## 4. The `remote` buildx driver, not the `kubernetes` driver

**Because** the runner only dials an endpoint. The kubernetes driver would need
RBAC in the runner namespace and would create and destroy a builder pod per
build, discarding the warm cache that is the whole point.

**Cost:** the builder must already exist; there is no self-provisioning.

## 5. Native multi-arch through a multi-node builder, not QEMU

**Because** each platform builds on hardware of that architecture with no
emulation penalty — QEMU costs 3–10× on instruction-heavy steps.

**Cost:** an arm64 node pool, and a multi-arch build needs a Ready shard on both
architectures.

## 6. mTLS as the access boundary

**Because** a client certificate is the one control that works regardless of
the cluster's network dataplane. Server certificates carry a wildcard SAN per
architecture, so changing the shard count needs no re-issue.

**Cost:** NetworkPolicy is defence in depth only — on clusters whose CNI does
not enforce it, certificate distribution *is* the access control, and every
namespace that receives the client Secret can reach the fleet and write into
shared caches.

## 7. Shards hold no cloud credentials

**Because** registry pull and push credentials are resolved by the runner and
arrive per session in the gRPC request. The shard is a compute resource, not an
identity.

**Cost:** never attach an IAM binding or a service account to these pods; a
build that needs cloud access gets it through the runner.

## 8. Requests equal limits, one shard per node

**Because** Guaranteed QoS earns an exclusive cpuset under the static CPU
manager policy instead of a CFS quota, which removes CFS throttling entirely, and
the HPA's utilisation (usage ÷ request) only means
something when requests are real and stay put.

**Cost:** capacity is reserved whether or not it is in use. Any request
right-sizing automation (VPA and similar) must be excluded from the namespace.
Such tools rewrite requests at admission to whatever the pod has recently used,
which drops QoS to Burstable, lets several shards bin-pack onto one node, and
makes the HPA signal meaningless.

## 9. Admission cap at 80% of the CPU limit

**Because** a compile-heavy build saturates a shard well below one build per
core; beyond that, concurrency time-slices the CPU. Queueing steps past the cap
keeps throughput unchanged while holding per-build latency and memory flat.

**Cost:** the cap is a count derived from cores, not a saturation measurement,
so it fires later than ideal for compile-heavy workloads. A CPU-based verdict is
the known upgrade.

## 10. Spill decided client-side, not by a server-side queue or proxy

**Because** it keeps the plain remote-driver model — no extra hop and no shared
queue to become the bottleneck — and the client already has the ranked shard
list.

**Cost:** the decision is point-in-time, taken once at builder setup. A job that
probes before the threshold is crossed stays pinned to a shard that later
saturates.

## 11. CPU as the primary autoscaling signal; accepted builds as a refinement

**Because** CPU is fast and always available, and scale-out on CPU alone works
under load. The external metric closes a real gap — a shard blocked
on a registry or a cache export reads ~0% CPU while holding every build it
accepted — but a *failing* external metric freezes scale-down entirely.

**Cost:** the metric is opt-in, wired through the operator's own pipeline, and
must be watched: a query that returns no series leaves the fleet pinned at
`maxReplicas` until it is fixed.

## 12. Cache PVCs retained on scale-in

**Because** a returning ordinal comes back warm rather than re-warming from the
registry.

**Cost:** idle disks between the HPA minimum and maximum.

## 13. Registry cache is the re-warm substrate, not the primary cache

**Because** every build reads it and a cold shard uses it to recover, but the
per-build export is pure network cost when the shard's own disk is already warm.
Only release, single-platform builds write it: buildx exports one ref from each
node and the last writer wins for multi-platform (docker/buildx#1044).

**Cost:** multi-platform builds rely on the shard disk alone. The GitHub Actions
cache backend is excluded for the same reason and one more — under load it
dominated build time while the shards sat idle.

## 14. Cache mounts stripped on release builds

**Because** a `RUN --mount=type=cache` mount is shared mutable scratch that any
repository's pull request on the same shard can write into, and a released
artifact must not consume it. BuildKit has no build-time flag for this, so the
Dockerfile is rewritten.

**Cost:** release builds are slower — a fresh dependency fetch. PR builds keep
their mounts, which is where most of the speed-up lives.

## 15. Readiness fast, liveness loose

**Because** buildkitd listens about two seconds after start; a 30 s readiness
period held every shard NotReady for an extra ~31 s per rollout. And an exec
liveness probe under load false-positives, and a liveness kill takes every
in-flight build with it.

**Cost:** liveness is a TCP check only. A wedged-but-listening daemon would not
be restarted automatically; readiness (a real gRPC round-trip) removes it from
the Service instead.

## 16. Ten-minute termination grace

**Because** buildkitd drains in-flight builds on SIGTERM and the Kubernetes
default of 30 s cuts them mid-step.

**Cost:** any rollout while builds are active is slow by design.

## 17. Ship a rebuild of the upstream image, not the upstream image

**Because** the upstream rootless image bundles binaries built elsewhere (CNI
plugins arrive prebuilt on an older Go) and pins dependency versions that pick
up CVEs between releases, so a scanner reports findings no chart change can
clear. Rebuilding every component from the same upstream tags on one current
toolchain, with those modules raised, is the only lever that moves the count —
and doing it weekly, gated on the scan and signed, makes it a maintained
artefact rather than a one-off.

**Cost:** the image is now this project's to maintain: upstream releases need a
pin bump, a compile break on a raised dependency is ours to fix, and users must
trust this repository's build rather than Docker Hub's. The upstream image
remains a one-line `image.repository` override.
