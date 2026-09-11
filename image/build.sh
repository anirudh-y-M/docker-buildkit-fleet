#!/usr/bin/env bash
# Build the rebuilt BuildKit image with the pins from versions.env.
#
#   image/build.sh --platform linux/amd64 --load -t buildkit:local
#   image/build.sh --platform linux/amd64,linux/arm64 --push -t ghcr.io/<owner>/<repo>/buildkit:v0.33.0-rootless
#
# Any extra arguments are passed to `docker buildx build` unchanged.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
args=()
while IFS='=' read -r k v; do
  [[ "$k" =~ ^[A-Z_]+$ ]] || continue
  args+=(--build-arg "$k=$v")
done < "$here/versions.env"
exec docker buildx build "${args[@]}" "$@" "$here"
