#!/usr/bin/env bash
# Exit 0 if the Dockerfile has a `--mount=...type=cache...` token AFTER its last
# FROM line (i.e. in the final stage), else exit 1. Used to warn that stripping
# will bake the mount target's contents into the shipped image.
set -euo pipefail
f="${1:?usage: has-final-stage-cache-mount.sh <dockerfile>}"
last_from=$(grep -inE '^[[:space:]]*FROM[[:space:]]' "$f" | tail -1 | cut -d: -f1)
[[ -n "$last_from" ]] || exit 1
tail -n +"$((last_from + 1))" "$f" | grep -qE -- '--mount=[^[:space:]]*type=cache'
