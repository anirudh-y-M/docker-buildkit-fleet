# strip-cache-mounts

`RUN --mount=type=cache` is what makes builds on a shared BuildKit worker fast:
pip, npm, Go and apt caches persist on the worker between builds. It is also
shared, mutable scratch that *any* repository's pull request on the same worker
can write into. A release build must not consume it, or a poisoned dependency in
a shared cache could be baked into a production image.

BuildKit has no build-time flag for this (`--no-cache` only affects the layer
cache), so this action rewrites the Dockerfile: on release builds it produces a
copy with every cache mount removed, on other builds it returns the original.

```yaml
- id: dockerfile
  uses: <owner>/image-buildkit-fleet/actions/strip-cache-mounts@v0.1.0
  with:
    dockerfile: Dockerfile
- uses: docker/build-push-action@v6
  with:
    file: ${{ steps.dockerfile.outputs.file }}   # required — otherwise the strip is a no-op
    push: true
    # The same predicate gates a shared registry cache export:
    cache-to: ${{ steps.dockerfile.outputs.is_release == 'true' && 'type=registry,ref=ghcr.io/acme/app:buildcache,mode=max,ignore-error=true' || '' }}
```

## The release predicate

A build is a release when the ref is a **tag**, or the **production branch** on
a non-PR event (`push`, `workflow_dispatch`, `schedule`). `pull_request` and
`pull_request_target` never qualify — on `pull_request_target` the ref *is* the
production branch, which is why the event, not the ref, decides.

The production branch resolves in order: `production-branch` input →
`production-branch-config` file → the event payload's default branch. If none
resolves, the build is treated as **non-release** with a warning, rather than
guessing. Tags are unaffected.

The action owns this predicate so callers cannot hand-roll it wrong: a hardcoded
`main` in a caller silently misclassifies every repository whose production
branch differs, disabling the control with no signal.

## Inputs and outputs

| input | default | |
|---|---|---|
| `dockerfile` | required | relative to the repository root |
| `strip` | `auto` | `true`/`false` force the decision |
| `production-branch` | empty | set when it is not the default branch |
| `production-branch-config` | empty | JSON `{ "owner/repo": { "production_branch": "…" } }` |

| output | |
|---|---|
| `file` | the Dockerfile to build with — original, or the stripped copy under `RUNNER_TEMP` |
| `is_release` | `true`/`false`, independent of any `strip` override |

## Final-stage mounts

Stripping a mount in the *final* stage bakes whatever the `RUN` wrote into the
mount target (e.g. `/root/.cache/pip`) into the shipped image. The action warns
when it sees one. The fix is to install dependencies in a builder stage.

## Known limit

This is a textual pass, not a Dockerfile parser. Comments are skipped; the
literal `--mount=…type=cache…` token inside a `RUN` shell string would also be
removed. A BuildKit-frontend parse is the robust upgrade.

## Tests

```bash
bash actions/strip-cache-mounts/is-release_test.sh
bash actions/strip-cache-mounts/strip-cache-mounts_test.sh
```
