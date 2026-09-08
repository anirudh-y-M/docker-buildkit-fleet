#!/usr/bin/env bash
# Remove every `--mount=...type=cache...` token from a Dockerfile so a release
# build does not consume the shared, mutable RUN scratch cache. type=secret and
# type=bind are preserved. Never mutates the input.
#
# KNOWN LIMIT: a textual pass, not a Dockerfile parser. Comments are skipped, but
# the literal token inside a RUN shell string would also be removed. A
# BuildKit-frontend parse is the robust upgrade.
set -euo pipefail
in="${1:?usage: strip-cache-mounts.sh <in> <out>}"
out="${2:?usage: strip-cache-mounts.sh <in> <out>}"
[ -r "$in" ] || { echo "strip-cache-mounts.sh: cannot read '$in'" >&2; exit 1; }

# Pass 1: [^[:space:]]* on both sides of type=cache captures the whole
# comma-joined token whatever order the options are in.
# Pass 2: drop lines left holding only a backslash. `RUN --mount=... \` followed
# by the command on the next line otherwise leaves an empty continuation line,
# which BuildKit warns on. The trailing [[:space:]]* matches BuildKit's own
# continuation regex (`\\[ \t]*$`).
sed -E '/^[[:space:]]*#/!s/--mount=[^[:space:]]*type=cache[^[:space:]]*[[:space:]]*//g' "$in" |
  sed -E '/^[[:space:]]*\\[[:space:]]*$/d' > "$out"
