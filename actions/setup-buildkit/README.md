# setup-buildkit

Point `docker buildx` at a shared, in-cluster BuildKit fleet deployed with the
[buildkit-fleet chart](../../charts/buildkit-fleet). A drop-in replacement for
`docker/setup-buildx-action`: every later `docker/build-push-action` or
`docker buildx build --push` step uses the fleet without changes.

```yaml
- uses: <owner>/image-buildkit-fleet/actions/setup-buildkit@v0.1.0
  with:
    platforms: linux/amd64,linux/arm64
- uses: docker/build-push-action@v6
  with:
    platforms: linux/amd64,linux/arm64   # set here too: this drives the build
    push: true
    tags: ghcr.io/acme/app:${{ github.sha }}
```

## What it does

1. **Discovers** the live shards of each architecture by walking the headless
   Service's per-pod DNS names (`buildkit-amd64-0`, `-1`, …) until two
   consecutive names fail to resolve. The autoscaler changes the count, so
   nothing static is trusted. No Kubernetes API, no RBAC.
2. **Routes** the repository to a home shard by rendezvous hash of
   `routing-key` (default: the repository name). Same key, same shard, on both
   architectures — so a repository always finds its warm cache, and changing the
   shard count moves only ~1/N of repositories.
3. **Spills** when the home shard reports itself at its admission cap: waits
   15 s for a slot (halving at each later rank, ~26 s bounded), then attaches the
   next-ranked shard. Cold there, but a cold build beats a queue. When every
   shard is full it queues on the home shard, where the cache is.
4. **Fails over** to the next-ranked shard when one is unreachable.
5. **Joins** one shard per architecture into a single buildx builder over the
   `remote` driver with mTLS, and selects it as default.

## Requirements on the runner

- The fleet's client certificate Secret mounted at `cert-dir` (default `/certs`)
  with `ca.crt`, `tls.crt`, `tls.key`. See
  [examples/runner-mount.yaml](../../examples/runner-mount.yaml) for an
  actions-runner-controller scale set.
- Cluster DNS able to resolve the fleet's per-pod names.
- `docker buildx` on the runner image.
- Network reachability to the fleet namespace on :1234 (and :8080 for the load
  probe; without it the action fails open and routes without load awareness).

## Inputs

| input | default | notes |
|---|---|---|
| `platforms` | `linux/amd64` | `linux/amd64`, `linux/arm64`, or both |
| `shard-domain-suffix` | `buildkit.svc.cluster.local` | `<namespace>.svc.cluster.local` of the release |
| `service-prefix` | `buildkit` | the chart's `namePrefix` |
| `cert-dir` / `ca-file` / `cert-file` / `key-file` | `/certs`, `ca.crt`, `tls.crt`, `tls.key` | client mTLS material |
| `builder-name` | `buildkit-fleet` | |
| `routing-key` | `${{ github.repository }}` | widen for repositories that build many independent images |
| `shards-fallback` | empty | shard count assumed when DNS returns nothing; empty fails fast |
| `max-shards` | `64` | discovery walk bound |
| `full-retry-seconds` | `15` | wait at the home shard before spilling; 0 disables |

## Outputs

| output | example |
|---|---|
| `builder` | `buildkit-fleet` |
| `shard` | `1` — the key's home shard |
| `selected` | `amd64=1,arm64=0` — differs from `shard` after a spill or failover |

## Multi-arch: set `platforms` twice

`platforms` on this action configures the *builder* (which shards join as
nodes). `platforms` on `docker/build-push-action` drives the *build*. With it on
the setup step alone, buildx builds only the default platform and the arm64
shards sit idle.

## Release builds

Pair with [strip-cache-mounts](../strip-cache-mounts) so released images never
consume the shared, mutable `RUN --mount=type=cache` scratch.

## Tests

```bash
bash actions/setup-buildkit/shard_test.sh
bash actions/setup-buildkit/fleet_test.sh
```
