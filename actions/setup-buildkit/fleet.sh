# Shard discovery and load probing. bash + getent/nslookup + curl/wget only;
# never the Kubernetes API, so the runner needs zero RBAC.
#
# Discovery: the fleet's headless Service publishes one A record per pod
# (<prefix>-<arch>-<n>.<prefix>-<arch>.<suffix>, not-ready pods included) and
# StatefulSet ordinals are contiguous, so the live shard set is "0.. until two
# consecutive names fail to resolve". A pod being recreated or stuck Pending has
# no record; tolerating one gap keeps it from hiding every shard above it. The
# autoscaler changes the count, so nothing static is trusted when DNS answers.
#
# Load: each shard serves GET :8080/load -> {"inflight":N,"cap":M,"full":b}.
# "full" means the shard is at its admission cap and new steps would queue. The
# probe FAILS OPEN: no answer reads as "not full", so a fleet without the sidecar
# keeps plain rendezvous routing.

# Set by the action from its `service-prefix` input; must match the chart's
# namePrefix.
: "${BUILDKIT_SERVICE_PREFIX:=buildkit}"

shard_host() {  # <arch> <ordinal> <suffix>
  printf '%s-%s-%s.%s-%s.%s' "$BUILDKIT_SERVICE_PREFIX" "$1" "$2" "$BUILDKIT_SERVICE_PREFIX" "$1" "$3"
}

# resolve_host <fqdn> -> 0 when it has an address record. Tests stub this.
resolve_host() {
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$1" >/dev/null 2>&1
  elif command -v nslookup >/dev/null 2>&1; then
    nslookup "$1" >/dev/null 2>&1
  else
    return 2
  fi
}

# discover_ordinals <arch> <suffix> [max] -> existing ordinals, one per line.
# One retry per name so a transient resolver error does not truncate the set;
# the walk ends after two consecutive misses.
discover_ordinals() {
  local arch="$1" suffix="$2" max="${3:-64}" ord host misses=0
  for ((ord=0; ord<max; ord++)); do
    host=$(shard_host "$arch" "$ord" "$suffix")
    if resolve_host "$host" || resolve_host "$host"; then
      misses=0; echo "$ord"
    else
      misses=$((misses+1)); (( misses >= 2 )) && break
    fi
  done
}

# fetch_url <url> -> body on stdout; non-zero on any failure. 2s budget: this
# runs once per shard in rank order and must never dominate setup time.
fetch_url() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --connect-timeout 1 -m 2 "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- -T 2 "$1"
  else
    return 2
  fi
}

# probe_is_full <json> -> 0 iff the body says "full": true.
probe_is_full() {
  printf '%s' "$1" | grep -Eq '"full"[[:space:]]*:[[:space:]]*true'
}

# shard_full <arch> <ordinal> <suffix> -> 0 = at cap (skip it); 1 = not full,
# or unknown (fail open).
shard_full() {
  local body
  body=$(fetch_url "http://$(shard_host "$1" "$2" "$3"):8080/load" 2>/dev/null) || return 1
  probe_is_full "$body"
}

# full_retry_wait <rank-index> [base-seconds] -> seconds to wait before
# re-probing a shard that just reported full: 15, 7, 3, 1, 0, 0...
#
# Ranks are not equivalent. Rank 0 holds this key's warm cache, so a short wait
# there beats the cold build a spill costs; every later rank is equally cold, so
# waiting buys nothing. Reaching 0 bounds the total added latency at ~26s no
# matter how many shards exist. Base from BUILDKIT_FULL_RETRY_SECONDS; 0
# disables the retry.
full_retry_wait() {
  local idx="$1" base="${2:-${BUILDKIT_FULL_RETRY_SECONDS:-15}}"
  if ! [[ "$base" =~ ^[0-9]+$ ]] || (( base == 0 )) || (( idx >= 8 )); then
    echo 0; return
  fi
  echo $(( base >> idx ))
}
