# Contributing

Thanks for taking the time. This project is small and opinionated, so a short
issue describing what you want to change — and what you measured — goes a long
way before a large pull request.

## Ground rules

- **Measure, then change.** The defaults are starting points, not truths. If you
  change a default (cap ratio, probe timings, HPA window, GC
  target), say what you observed and on what hardware.
- **Keep the actions dependency-free.** `setup-buildkit` and
  `strip-cache-mounts` are bash plus coreutils on purpose: they must run on any
  runner image with `docker buildx`, and they must never need Kubernetes RBAC.
- **Fail open on the load probe, fail closed on the release predicate.** A
  missing probe answer must degrade to plain routing; an unresolvable production
  branch must classify as a non-release build.

## Running the tests

```bash
bash actions/setup-buildkit/shard_test.sh
bash actions/setup-buildkit/fleet_test.sh
bash actions/strip-cache-mounts/is-release_test.sh
bash actions/strip-cache-mounts/strip-cache-mounts_test.sh
helm lint charts/buildkit-fleet
helm template t charts/buildkit-fleet --namespace buildkit > /dev/null
```

CI runs the same set on every pull request.

## Chart changes

- Bump `version` in `Chart.yaml` for any user-visible change (semver).
- Every value gets a comment in `values.yaml` saying *why*, not just what.
- Anything a user would need at 3 a.m. belongs in `docs/operations.md`.

## Documentation

Write for the person who has never seen the system. Prefer a concrete number
over an adjective, and a sentence over a bullet when the sentence explains a
cause.
