# Rendezvous (highest-random-weight) hashing: rank shards by weight for a key,
# highest first. Weight = first 16 hex chars of sha256("<key>:<ordinal>").
# Fixed-width hex means lexicographic order == numeric order, so `sort -r`
# orders by weight. Adding or removing a shard moves only the keys whose
# top-weighted shard changed (~1/N of them); modulo would reshuffle nearly all.
#
# hrw_rank_list <key> <ordinal>... -> the given ordinals in descending weight
#                                     order, one per line. Line 1 is the home
#                                     shard; the rest is the spill/failover
#                                     order. The set need not be contiguous.
# hrw_ranked <key> <N>              -> hrw_rank_list over 0..N-1.
hrw_rank_list() {
  local key="$1" ord w; shift
  for ord in "$@"; do
    w=$(printf '%s:%s' "$key" "$ord" | sha256sum | cut -c1-16)
    printf '%s %s\n' "$w" "$ord"
  # LC_ALL=C pins byte-order collation so the hex weights sort numerically.
  done | LC_ALL=C sort -r | awk '{print $2}'
}

hrw_ranked() {
  local key="$1" n="$2"
  hrw_rank_list "$key" $(seq 0 $((n-1)))
}
