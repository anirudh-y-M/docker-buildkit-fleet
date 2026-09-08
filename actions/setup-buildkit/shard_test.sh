#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./shard.sh

fail=0
assert_eq() { if [[ "$1" != "$2" ]]; then echo "FAIL: $3 (got '$1', want '$2')"; fail=1; else echo "ok: $3"; fi; }

p1=$(hrw_ranked "example/foo" 3 | head -1)
p2=$(hrw_ranked "example/foo" 3 | head -1)
assert_eq "$p1" "$p2" "deterministic home shard"

got=$(hrw_ranked "example/bar" 4 | sort -n | tr '\n' ',')
assert_eq "$got" "0,1,2,3," "ranked list is a full permutation of 0..3"

assert_eq "$(hrw_ranked "example/anything" 1)" "0" "N=1 -> shard 0"

distinct=$(for i in $(seq 1 300); do hrw_ranked "example/repo-$i" 3 | head -1; done | sort -u | wc -l | tr -d ' ')
assert_eq "$distinct" "3" "all 3 shards are some key's home"

# Rendezvous remap bound: N 3->4 moves < 40% of keys (expected ~25%).
moved=0
for i in $(seq 1 300); do
  a=$(hrw_ranked "example/repo-$i" 3 | head -1)
  b=$(hrw_ranked "example/repo-$i" 4 | head -1)
  [[ "$a" != "$b" ]] && moved=$((moved+1))
done
if (( moved < 120 )); then echo "ok: remap bound ($moved/300 moved)"; else echo "FAIL: remap $moved/300 >= 120"; fail=1; fi

uniq=$(hrw_ranked "example/failover" 3 | sort -u | wc -l | tr -d ' ')
assert_eq "$uniq" "3" "failover ranking has 3 distinct shards"

exit $fail
