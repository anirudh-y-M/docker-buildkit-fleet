# docker-buildkit-fleet

**A shared, horizontally scalable BuildKit fleet for CI — and the GitHub Actions that route builds to it for self-hosted runners.**

Ephemeral CI runners throw their build cache away after every job. The solution can be used for non-hosted runners too but the trust boundary i.e. netpol, certs usage will change as per the CI. **The Buildkit Fleet itself is CI agnostic**. 

Registry caches help, but a stateless worker still has to pull and unpack every cachedlayer before it can build on top of it — for a multi-gigabyte dependency layerthat is minutes of network transfer for a step buildx reports as `CACHED`. A warm BuildKit worker with the bytes already on local disk skips it entirely.

This repository packages a design that keeps that warm worker without making it
a single point of failure or a scaling ceiling:

- **A fleet of independent shards**, one StatefulSet per CPU architecture, one
  cache disk per shard, autoscaled per architecture.
- **Repository-sticky routing**: a rendezvous hash sends every build of a
  repository to the same shard on every architecture, so it always finds its
  cache. Changing the shard count moves only ~1/N of repositories.
- **Capacity control in three layers**: an admission cap per shard, a
  client-side spill to the next shard when the home shard is full, and an HPA
  that follows the daily curve.
- **Native multi-arch**: one `docker buildx` builder with an amd64 node and an
  arm64 node. No QEMU.
- **mTLS end to end**, and a release-build control that keeps a shared,
  mutable build cache out of production images.

## What is in the box

| path | what it is |
|---|---|
| [`charts/buildkit-fleet`](charts/buildkit-fleet) | Helm chart for the fleet: StatefulSets, headless Services, HPAs, PDBs, cert-manager trust chain, NetworkPolicy, load-probe sidecar |
| [`actions/setup-buildkit`](actions/setup-buildkit) | Drop-in for `docker/setup-buildx-action`: discovers shards over DNS, routes, spills, fails over, joins one buildx builder |
| [`actions/strip-cache-mounts`](actions/strip-cache-mounts) | Removes `RUN --mount=type=cache` on release builds and owns the "is this a release?" predicate |
| [`examples/`](examples) | Consumer workflows (single- and multi-arch) and the runner-side certificate mount |
| [`docs/`](docs) | [Architecture](docs/architecture.md) · [Design decisions](docs/design-decisions.md) · [Operations](docs/operations.md) · [Measuring your fleet](docs/measuring.md) |

## Quick start

**1. Install the fleet** (needs cert-manager and a StorageClass that supports
online expansion):

```bash
helm install buildkit oci://ghcr.io/anirudh-y-m/charts/buildkit-fleet --version 0.1.0 \
  --namespace buildkit --create-namespace \
  --set trust.clientCertificate.namespaces='{actions-runner}'
```

Or from a checkout: `helm install buildkit ./charts/buildkit-fleet -f charts/buildkit-fleet/examples/values-small.yaml`.

**2. Mount the client certificate into your runner pods** at `/certs` — see
[examples/runner-mount.yaml](examples/runner-mount.yaml). The chart issues the
Secret into every namespace listed in `trust.clientCertificate.namespaces`.

**3. Use it from a workflow:**

```yaml
- id: dockerfile
  uses: anirudh-y-M/docker-buildkit-fleet/actions/strip-cache-mounts@v0.1.0
  with:
    dockerfile: Dockerfile

- uses: anirudh-y-M/docker-buildkit-fleet/actions/setup-buildkit@v0.1.0
  with:
    platforms: linux/amd64,linux/arm64

- uses: docker/build-push-action@v6
  with:
    file: ${{ steps.dockerfile.outputs.file }}
    platforms: linux/amd64,linux/arm64
    push: true
    tags: ghcr.io/acme/app:${{ github.sha }}
```

Anything already running `docker buildx build --push` or `build-push-action`
routes to the fleet with no other change — `setup-buildkit` selects the builder
as default.

## How it fits together

```
 ns: buildkit
   StatefulSet buildkit-amd64            StatefulSet buildkit-arm64
     shard-0 [PVC]  shard-1 [PVC] …        shard-0 [PVC]  shard-1 [PVC] …
     ▲ headless Service, per-pod DNS       ▲ headless Service, per-pod DNS
     │ mTLS :1234                          │ mTLS :1234
     └───────────────┬─────────────────────┘
                     │
 ns: <your runners>  │  ephemeral runner pod, client cert at /certs
                     └─ setup-buildkit:
                          shards   = walk per-pod DNS until two names miss
                          home     = rendezvous_hash(repository) over the shard set
                          attach   = home shard, or next-ranked if home is full / down
                          builder  = one buildx builder with node-amd64 + node-arm64
```

Each shard is a single-writer BuildKit daemon with its own disk — BuildKit's
content store and metadata cannot be shared between daemons, so scale and HA
come from *more independent shards*, not replicas of one. The whole speed win is
cache locality, which is why routing is sticky rather than load-balanced.

## Why these defaults

Every number in `values.yaml` has a comment saying why. The short version:

- **Requests equal limits, one shard per node.** Guaranteed QoS earns an
  exclusive cpuset, and the HPA's utilisation only means something when nothing
  rewrites the requests after admission. Exclude the namespace from any
  right-sizing automation.
- **Admission cap at 80% of CPU.** Compile-heavy steps saturate a shard well
  below one build per core; beyond that point concurrency only time-slices the
  CPU and adds latency and memory. Steps past the cap queue inside
  BuildKit instead, keeping per-build latency and memory flat.
- **Spill before scale.** The HPA divides total usage by total requests, so one
  saturated shard beside one idle shard reads 50% against an 85% target. The
  client-side spill spreads load before the autoscaler can see it.
- **GC prunes to ~83% of the disk.** GC is lazy; the margin absorbs overshoot
  between sweeps.
- **Readiness fast, liveness loose.** buildkitd listens about two seconds after
  start, so readiness polls every five. Liveness is a plain TCP check: an exec
  probe under load false-positives, and a liveness kill takes every in-flight
  build with it.

## Image vulnerabilities

Artifact Hub scans the image the chart ships with Trivy, and BuildKit is a Go
binary on Alpine, so every CVE published against its dependencies or the Go
standard library after a release counts against it until the next one. None of
that is chart code, and pointing at a newer upstream tag only helps until the
next batch of CVEs lands.

So the chart ships a **rebuild of upstream** instead:
`ghcr.io/anirudh-y-m/docker-buildkit-fleet/buildkit`. It is `moby/buildkit` at the
same tag, compiled on a current Go toolchain with the flagged dependencies
raised, gated on a scan, signed with Sigstore, published multi-arch with
provenance and an SBOM, and rebuilt weekly. The chart pins it by digest. What is
in it, what differs from upstream, and how to verify the signature are in
[image/README.md](image/README.md).

You choose the image; it is just values:

```yaml
image:
  repository: docker.io/moby/buildkit      # upstream, as published
  tag: v0.33.0-rootless
  digest: ""
```

Anything with the upstream rootless layout works, including your own rebuild
(`image/build.sh` produces one). The load-probe sidecar can run a separate,
smaller image via `loadProbe.image`.

## Status

Treat `0.x` as "works, opinionated, expect the knobs to move". Issues and
measured counter-examples are very welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[Apache 2.0](LICENSE) — © 2026 Anirudh Yadav.
