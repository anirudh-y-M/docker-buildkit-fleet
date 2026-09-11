# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] — 2026-09-11

### Changed

- The default `image` is now a rebuild of upstream BuildKit,
  `ghcr.io/anirudh-y-m/docker-buildkit-fleet/buildkit:v0.33.0-rootless`, pinned by
  digest. Same version, layout, entrypoint and uid as `moby/buildkit`; the
  upstream image remains a supported choice via `image.repository`. Details in
  [image/README.md](image/README.md).

### Added

- A rebuilt BuildKit image (`image/`): upstream sources at the same tags,
  compiled on a current Go with patched dependencies, scan-gated, signed with
  Sigstore and published multi-arch with provenance and an SBOM, weekly, by the
  **Image** workflow, which then opens a PR pinning the chart to the new digest.
- `loadProbe.image` to run the load-probe sidecar from a different image than
  buildkitd.

### Security

- The rebuilt image scans clean of fixable critical and high vulnerabilities in
  every bundled binary and the Alpine base, against 193 findings (1 critical) on
  the upstream v0.33.0-rootless image the chart shipped in 0.1.2.

## [0.1.2] — 2026-09-10

### Security

- Bump the BuildKit image from v0.27.0 to v0.33.0 and pin it by digest. The
  v0.27.0 image carried 616 known vulnerabilities (15 critical); v0.33.0 carries
  193 (1 critical), all in upstream Go dependencies and Alpine packages awaiting
  a new upstream build. No chart behaviour changes; buildkitd flags and the
  rootless entrypoint are unchanged across the range.

## [0.1.1] — 2026-09-09

### Changed

- Artifact Hub repository metadata.

## [0.1.0] — 2026-09-08

Initial public release.

### Added

- **buildkit-fleet Helm chart**: per-architecture StatefulSets of rootless
  BuildKit shards with one cache disk each, headless Services with per-pod DNS,
  cert-manager mTLS (wildcard server SAN, client certificate per runner
  namespace), an admission cap derived from the CPU limit, a load-probe
  sidecar, per-architecture HPAs with an optional external "builds accepted"
  metric, PodDisruptionBudgets and a NetworkPolicy.
- **setup-buildkit action**: DNS shard discovery, rendezvous routing, bounded
  spill on a full shard, failover, and a multi-node buildx builder over the
  `remote` driver.
- **strip-cache-mounts action**: removes `RUN --mount=type=cache` on release
  builds, owns the release predicate, warns on final-stage mounts.
- Architecture, design-decision, operations and sizing documentation.
