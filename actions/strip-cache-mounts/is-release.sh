#!/usr/bin/env bash
# Decide whether this is a "release build": a tag, or the production branch on a
# non-PR event. Gates the cache-mount strip and any shared cache export.
#
# PR-family events never qualify. That matters for pull_request_target, where
# the ref IS the production branch: the event check, not the ref, excludes it.
#
# Usage: is-release.sh [production-branch] [fallback-default-branch] [config-json]
# Reads: GITHUB_REF_TYPE, GITHUB_REF_NAME, GITHUB_EVENT_NAME, GITHUB_REPOSITORY
# Prints: <is_release>TAB<production_branch>TAB<source>
#
# config-json, when given, maps repositories to production branches:
#   { "owner/repo": { "production_branch": "release" } }
set -euo pipefail

override="${1:-}"
fallback="${2:-}"
cfg="${3:-}"

# Resolution order: explicit input > config file > caller's fallback.
branch="${override}"
src="input"
if [ -z "${branch}" ] && [ -n "${cfg}" ] && command -v jq >/dev/null 2>&1 && [ -r "${cfg}" ]; then
  branch=$(jq -r --arg repo "${GITHUB_REPOSITORY:-}" '.[$repo].production_branch // empty' < "${cfg}" 2>/dev/null || true)
  src="config"
fi
if [ -z "${branch}" ]; then
  branch="${fallback}"
  src="default_branch"
fi
[ -n "${branch}" ] || src="unresolved"

is_release=false
if [ "${GITHUB_REF_TYPE:-}" = "tag" ] ||
   { [ -n "${branch}" ] && [ "${GITHUB_REF_NAME:-}" = "${branch}" ]; }; then
  case "${GITHUB_EVENT_NAME:-}" in
    pull_request|pull_request_target) ;;
    *) is_release=true ;;
  esac
fi

printf '%s\t%s\t%s\n' "${is_release}" "${branch}" "${src}"
