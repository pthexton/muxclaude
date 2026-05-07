#!/usr/bin/env bash
# muxclaude — CI cache fetcher.
#
# Fetches PR + CI check status for the current branch and writes a JSON cache
# the sidebar reads. Designed to be invoked from statusline.sh in the
# background — never blocks rendering, never panics on network/auth errors.
#
# Concurrency: a per-cache lock dir (mkdir is atomic on POSIX) prevents
# two fetches racing. Stale locks older than 2 minutes are reclaimed in case
# a previous fetcher died.
#
# Usage: ci-fetch.sh <working_dir> <cache_file>
#
# Cache file shape (jq-friendly):
#     { fetched_at: <unix>,
#       branch:    "...",
#       commit_sha:"...",
#       repo:      "owner/name",
#       pr:        null | { number, title, url, createdAt },
#       checks:    [ { bucket, name, state, workflow }, ... ] }
#
# Requires: git, gh, jq.

set -uo pipefail

DIR=${1:?missing working_dir}
CACHE=${2:?missing cache_file}
LOCK="${CACHE}.lock"
NOW=$(date +%s)

mkdir -p "$(dirname "$CACHE")"

# Acquire lock or bail.
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -d "$LOCK" ]; then
    age=$(( NOW - $(stat -f '%m' "$LOCK" 2>/dev/null || echo "$NOW") ))
    if [ "$age" -lt 120 ]; then
      exit 0
    fi
    rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

cd "$DIR" 2>/dev/null || exit 0

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
COMMIT_SHA=$(git rev-parse HEAD 2>/dev/null) || COMMIT_SHA=""
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || exit 0

# `gh pr view` (no args) resolves the PR for the current branch. Returns
# non-zero if there isn't one — that's an expected, non-error state.
# `createdAt` lets statusline.sh poll aggressively for a brief window after
# a PR is opened, while GitHub is still registering the first workflow run
# (otherwise we cache `pr: <new>, checks: []` and the staleness rule treats
# it as terminal-no-checks and never auto-refetches).
PR_JSON=$(gh pr view --json number,title,url,createdAt 2>/dev/null) || PR_JSON=""

if [ -z "$PR_JSON" ]; then
  jq -n \
    --arg branch "$BRANCH" \
    --arg repo "$REPO" \
    --arg commit_sha "$COMMIT_SHA" \
    --argjson now "$NOW" \
    '{fetched_at: $now, branch: $branch, commit_sha: $commit_sha, repo: $repo, pr: null, checks: []}' \
    > "$CACHE.tmp" \
    && mv "$CACHE.tmp" "$CACHE"
  exit 0
fi

# `gh pr checks --json` returns the latest job rollup for the PR.
CHECKS_JSON=$(gh pr checks --json bucket,name,state,workflow 2>/dev/null) || CHECKS_JSON="[]"
# Defend against any non-JSON output:
echo "$CHECKS_JSON" | jq empty 2>/dev/null || CHECKS_JSON="[]"

jq -n \
  --arg branch "$BRANCH" \
  --arg repo "$REPO" \
  --arg commit_sha "$COMMIT_SHA" \
  --argjson pr "$PR_JSON" \
  --argjson checks "$CHECKS_JSON" \
  --argjson now "$NOW" \
  '{fetched_at: $now, branch: $branch, commit_sha: $commit_sha, repo: $repo, pr: $pr, checks: $checks}' \
  > "$CACHE.tmp" \
  && mv "$CACHE.tmp" "$CACHE"
