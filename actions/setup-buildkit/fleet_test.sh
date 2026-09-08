#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./shard.sh
source ./fleet.sh

fail=0
assert_eq() { if [[ "$1" != "$2" ]]; then echo "FAIL: $3 (got '$1', want '$2')"; fail=1; else echo "ok: $3"; fi; }

# --- hrw_rank_list ------------------------------------------------------------
assert_eq "$(hrw_rank_list example/foo 0 1 2 3 | tr '\n' ,)" "$(hrw_ranked example/foo 4 | tr '\n' ,)" "hrw_rank_list over 0..3 == hrw_ranked 4"
assert_eq "$(hrw_rank_list example/bar 0 1 3 | sort -n | tr '\n' ,)" "0,1,3," "ranks exactly the given ordinals"
viol=0
for i in $(seq 1 200); do
  a=$(hrw_rank_list "example/repo-$i" 0 1 2 3 | head -1)
  b=$(hrw_rank_list "example/repo-$i" 0 1 3 | head -1)
  if [[ "$a" != "2" && "$a" != "$b" ]]; then viol=$((viol+1)); fi
done
assert_eq "$viol" "0" "removing a shard never moves keys homed elsewhere"
assert_eq "$(hrw_rank_list example/baz 5 0 3 | sed -n 2p)" "$(hrw_rank_list example/baz 3 5 0 | sed -n 2p)" "ranking independent of input order"

# --- shard_host honours the service prefix -----------------------------------
assert_eq "$(shard_host amd64 2 ns.svc.cluster.local)" "buildkit-amd64-2.buildkit-amd64.ns.svc.cluster.local" "default prefix"
assert_eq "$(BUILDKIT_SERVICE_PREFIX=bk shard_host arm64 0 svc)" "bk-arm64-0.bk-arm64.svc" "custom prefix"

# --- discover_ordinals (resolver stubbed) ---------------------------------------
resolve_host() { case "$1" in buildkit-amd64-[0-2].buildkit-amd64.svc) return 0;; *) return 2;; esac; }
assert_eq "$(discover_ordinals amd64 svc | tr '\n' ,)" "0,1,2," "contiguous ordinals, stops after two misses"
assert_eq "$(discover_ordinals arm64 svc | tr '\n' ,)" "" "no records -> empty set (caller falls back)"
assert_eq "$(discover_ordinals amd64 svc 2 | tr '\n' ,)" "0,1," "max caps the walk"
resolve_host() { case "$1" in buildkit-amd64-[013].buildkit-amd64.svc) return 0;; *) return 2;; esac; }
assert_eq "$(discover_ordinals amd64 svc | tr '\n' ,)" "0,1,3," "one gap (ordinal 2) is tolerated"
resolve_host() { case "$1" in buildkit-arm64-[12].buildkit-arm64.svc) return 0;; *) return 2;; esac; }
assert_eq "$(discover_ordinals arm64 svc | tr '\n' ,)" "1,2," "Pending ordinal 0 does not hide 1 and 2"
flaky=0
resolve_host() { case "$1" in buildkit-amd64-1.*) flaky=$((flaky+1)); (( flaky == 1 )) && return 1; return 0;; buildkit-amd64-[0-3].*) return 0;; *) return 2;; esac; }
assert_eq "$(discover_ordinals amd64 svc | tr '\n' ,)" "0,1,2,3," "one failed lookup is retried"

# --- probe parsing / fail-open --------------------------------------------------
probe_is_full '{"inflight":22,"cap":22,"cpu_limit":28,"full":true}' && r=0 || r=$?
assert_eq "$r" "0" "full:true parsed"
probe_is_full '{"inflight":3,"cap":22,"cpu_limit":28,"full":false}' && r=0 || r=$?
assert_eq "$r" "1" "full:false parsed"
probe_is_full '<html>502 Bad Gateway</html>' && r=0 || r=$?
assert_eq "$r" "1" "garbage is not full"
fetch_url() { printf '{"inflight":22,"cap":22,"full":true}'; }
shard_full amd64 0 svc && r=0 || r=$?
assert_eq "$r" "0" "shard_full: probe says full -> skip"
fetch_url() { return 7; }
shard_full amd64 0 svc && r=0 || r=$?
assert_eq "$r" "1" "shard_full: unreachable probe fails OPEN"

# --- full_retry_wait: halving decay, bounded total -------------------------------
unset BUILDKIT_FULL_RETRY_SECONDS
seq_of() { local o=""; for i in 0 1 2 3 4 5; do o+="$(full_retry_wait "$i" "$@") "; done; echo "${o% }"; }
assert_eq "$(seq_of)" "15 7 3 1 0 0" "default base halves per rank and reaches 0"
tot=0; for i in $(seq 0 63); do tot=$(( tot + $(full_retry_wait "$i") )); done
assert_eq "$tot" "26" "total wait bounded at 26s over 64 shards"
assert_eq "$(seq_of 0)" "0 0 0 0 0 0" "base 0 disables the retry"
assert_eq "$(BUILDKIT_FULL_RETRY_SECONDS=8 full_retry_wait 1)" "4" "env base honoured"
assert_eq "$(BUILDKIT_FULL_RETRY_SECONDS=abc full_retry_wait 0)" "0" "non-numeric base -> 0"
assert_eq "$(full_retry_wait 8)" "0" "index guard: no undefined shift"

exit $fail
