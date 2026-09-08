# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

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
