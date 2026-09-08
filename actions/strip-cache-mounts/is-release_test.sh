#!/usr/bin/env bash
# Every branch of the release predicate is pinned: a wrong `false` silently lets
# a release build consume shared, mutable cache mounts.
set -euo pipefail
cd "$(dirname "$0")"
pass=0; fail=0

# check <expect_is_release> <expect_source> <description> -- [env...] [-- args...]
check() {
  local expect="$1" expect_src="$2" desc="$3"; shift 3
  [ "$1" = "--" ] && shift
  local envs=() args=()
  while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then shift; args=("$@"); break; fi
    envs+=("$1"); shift
  done
  local out is_release src
  out=$(env -u GITHUB_REF_TYPE -u GITHUB_REF_NAME -u GITHUB_EVENT_NAME -u GITHUB_REPOSITORY \
        "${envs[@]}" ./is-release.sh "${args[@]+"${args[@]}"}")
  is_release=$(cut -f1 <<<"$out"); src=$(cut -f3 <<<"$out")
  if [ "$is_release" = "$expect" ] && { [ -z "$expect_src" ] || [ "$src" = "$expect_src" ]; }; then
    echo "ok: $desc"; pass=$((pass + 1))
  else
    echo "FAIL: $desc — got is_release=$is_release source=$src, want is_release=$expect source=${expect_src:-any}"; fail=$((fail + 1))
  fi
}

# PR-family events are never releases, even when the ref is the production branch.
check false '' 'pull_request into main' -- GITHUB_EVENT_NAME=pull_request GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main -- '' main
check false '' 'pull_request_target (ref IS main)' -- GITHUB_EVENT_NAME=pull_request_target GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main -- '' main
check false '' 'tag ref on a PR event' -- GITHUB_EVENT_NAME=pull_request GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.0.0 -- '' main

# Release-named artifacts.
check true '' 'push to main' -- GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main -- '' main
check true '' 'tag push' -- GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.0.0 -- '' main
check true '' 'schedule on main' -- GITHUB_EVENT_NAME=schedule GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main -- '' main
check true '' 'workflow_dispatch on main' -- GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main -- '' main
check false '' 'push to a feature branch' -- GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=branch GITHUB_REF_NAME=feat/x -- '' main

# Production-branch resolution order.
check true input 'input override wins' -- GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=branch GITHUB_REF_NAME=rel -- rel main
check false default_branch 'non-default production branch not detected without config' -- GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=branch GITHUB_REF_NAME=master -- '' main

cfg=$(mktemp); trap 'rm -f "$cfg"' EXIT
printf '{"example/app":{"production_branch":"master"}}' > "$cfg"
check true config 'config supplies master' -- GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=branch GITHUB_REF_NAME=master GITHUB_REPOSITORY=example/app -- '' main "$cfg"
check false config 'config master => main push is not a release' -- GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main GITHUB_REPOSITORY=example/app -- '' main "$cfg"
check true input 'input beats config' -- GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=branch GITHUB_REF_NAME=rel GITHUB_REPOSITORY=example/app -- rel main "$cfg"
check false default_branch 'repo absent from config falls back' -- GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=branch GITHUB_REF_NAME=master GITHUB_REPOSITORY=example/other -- '' main "$cfg"

# Unresolvable production branch: fail safe (non-release), except for tags.
check false unresolved 'unresolvable production branch on a push => non-release' -- GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main -- '' ''
check true unresolved 'unresolvable production branch still detects a tag' -- GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v2 -- '' ''

# Missing env (action used outside Actions) must not blow up.
check false '' 'no github env at all' -- IGNORED=1 -- '' main

echo; echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
