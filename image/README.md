# Rebuilt BuildKit image

`ghcr.io/anirudh-y-m/docker-buildkit-fleet/buildkit` is `moby/buildkit`, rebuilt.
Same version, same layout, same rootless entrypoint and uid — compiled here on a
current Go toolchain with a handful of dependencies raised past their published
CVEs, then scanned, signed and published multi-arch every week.

## Why rebuild at all

A vulnerability scan of the upstream rootless image reports findings that have
nothing to do with BuildKit's own code:

| where | what | why it is there |
|---|---|---|
| `buildkit-cni-*` | Go standard library | upstream **downloads** the CNI plugins as prebuilt release binaries, compiled by that project on an older Go |
| `rootlesskit`, `buildkit-runc` | `golang.org/x/crypto`, `golang.org/x/net` | those projects' `go.mod` pins, older than the fixed versions |
| `buildkitd` | `github.com/moby/go-archive` | upstream `go.mod` pin |
| Alpine | `libcurl` and friends | the base image is older than the package fix |

None of these can be fixed from a Helm chart, and they persist in upstream's
nightly builds too. Rebuilding every component from the same upstream tags on
one toolchain, with those modules raised, is the only lever that moves the
count — so that is what `Dockerfile` does. It follows upstream's own
`Dockerfile` stage for stage; the differences are deliberate and listed below.

## What is different from upstream

- **Toolchain:** `GOTOOLCHAIN=local` on `golang:<GO_VERSION>`, so no component
  can pull an older Go through its module's `toolchain` line.
- **CNI plugins built from source** at the same tag upstream downloads binaries for.
- **Dependencies raised** before compiling (`go get` + `go mod tidy` +
  `go mod vendor` where the project vendors): `golang.org/x/crypto`,
  `golang.org/x/net`, `github.com/moby/go-archive`. Exact versions in
  `versions.env`.
- **`apk upgrade`** in the final stage.
- **No QEMU binfmt emulators.** The fleet builds each architecture on a shard of
  that architecture; emulation has no role. If you need `--platform` builds on a
  single-arch shard, use the upstream image.
- **Version string** reads `v0.33.0.m` — upstream's own convention for a
  modified tree.

## Pins

`versions.env` is the single source of truth. Every line becomes a
`--build-arg`; the workflow and `build.sh` both read it.

| pin | bump when |
|---|---|
| `BUILDKIT_VERSION`, `RUNC_VERSION`, `ROOTLESSKIT_VERSION`, `CNI_VERSION` | the upstream project releases |
| `GO_VERSION` | a Go security release lands — this alone clears standard-library findings |
| `ALPINE_VERSION` | a new Alpine minor; patch releases arrive via `apk upgrade` |
| `XCRYPTO_VERSION`, `XNET_VERSION`, `GOARCHIVE_VERSION` | a CVE is published against them |

## How it is published

The **Image** workflow (`.github/workflows/image.yml`) runs on changes under
`image/`, weekly, and on demand:

1. builds `linux/amd64` locally and smoke-tests it (`buildkitd --version`,
   uid 1000, busybox `nc -e` for the chart's load probe, every bundled binary present);
2. **gates** on Trivy — any fixable `CRITICAL` or `HIGH` fails the run and nothing is pushed;
3. builds and pushes `linux/amd64,linux/arm64` with SLSA provenance and an SBOM attached;
4. signs the digest with Sigstore keyless (`cosign`), identity = this repository's workflow;
5. opens a pull request pinning the chart's `image.digest` to what it just built.

Tags: `<BUILDKIT_VERSION>-rootless` (moves on each rebuild),
`<BUILDKIT_VERSION>-rootless-<yyyymmdd>` (immutable), `latest-rootless`. The
chart pins by digest, so a rebuild is always a reviewed change.

## Verify what you run

```bash
cosign verify ghcr.io/anirudh-y-m/docker-buildkit-fleet/buildkit@sha256:<digest> \
  --certificate-identity-regexp '^https://github.com/anirudh-y-M/docker-buildkit-fleet/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

docker buildx imagetools inspect ghcr.io/anirudh-y-m/docker-buildkit-fleet/buildkit@sha256:<digest> \
  --format '{{ json .Provenance }}'
```

## Build it yourself

```bash
image/build.sh --platform linux/amd64 --load -t buildkit:local
trivy image --severity CRITICAL,HIGH --ignore-unfixed buildkit:local
```

Point the chart at your own registry with `image.repository`, `image.tag`,
`image.digest`. Nothing else changes.
