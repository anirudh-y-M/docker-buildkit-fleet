#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
out=$(mktemp); multi=$(mktemp); joined=$(mktemp); ws=$(mktemp); wsout=$(mktemp)
trap 'rm -f "$out" "$multi" "$joined" "$ws" "$wsout"' EXIT
./strip-cache-mounts.sh testdata/Dockerfile.with-mounts "$out"

fail=0
check() { if eval "$1"; then echo "ok: $2"; else echo "FAIL: $2"; fail=1; fi; }

check '! grep -vE "^[[:space:]]*#" "$out" | grep -q "type=cache"' "no type=cache token remains in instructions (any option position)"
check 'grep -q "mount=type=secret" "$out"'          "secret mounts preserved"
check 'grep -q "go mod download" "$out"'             "RUN command preserved (type=cache first)"
check 'grep -q "apt-get update" "$out"'              "RUN command preserved (type=cache not first)"
check 'grep -q "COPY --from=build /app /app" "$out"' "non-RUN lines untouched"
check '[[ $(grep -c "^RUN" "$out") -eq $(grep -c "^RUN" testdata/Dockerfile.with-mounts) ]]' "RUN line count unchanged"
check '! grep -qE "^[[:space:]]*\\\\$" "$out"'       "no empty continuation lines left behind"
check 'grep -q -- "apt/pip cache mounts stay in comments: --mount=type=cache" "$out"' "comment lines preserved verbatim"

printf 'FROM alpine\nRUN --mount=type=cache,target=/a \\\n    --mount=type=cache,target=/b \\\n    cd x && make all\n' > "$multi"
./strip-cache-mounts.sh "$multi" "$joined"
check '[[ "$(sed -e :a -e "/\\\\$/N; s/\\\\\n//; ta" "$joined" | tail -1 | tr -s " ")" == "RUN cd x && make all" ]]' \
  "multi-line RUN joins to the same command, mounts gone"

# Continuation backslash followed by trailing whitespace: BuildKit still treats
# it as a continuation, so the leftover empty line must be dropped too.
printf 'FROM golang:1.24\nRUN --mount=type=cache,target=/go/pkg/mod \\\n    --mount=type=cache,target=/root/.cache \\ \n    go build -o /m .\n' > "$ws"
./strip-cache-mounts.sh "$ws" "$wsout"
check '! grep -qE "^[[:space:]]*\\\\[[:space:]]*$" "$wsout"' "trailing space after the continuation backslash is handled"

check '! ./has-final-stage-cache-mount.sh testdata/Dockerfile.with-mounts'    "multi-stage builder-only mounts -> no final-stage hit"
check './has-final-stage-cache-mount.sh testdata/Dockerfile.final-stage-mount' "single-stage pip cache mount -> final-stage hit"
exit $fail
