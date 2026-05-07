#!/usr/bin/env bash
# muxclaude — PostToolUse hook.
#
# When a `gh pr create` Bash invocation succeeds, kicks off an immediate CI
# fetch so the sidebar doesn't sit on a stale "no PR" cache for up to 5
# minutes after the PR is opened.
#
# Hook payload (JSON on stdin), relevant fields only:
#   {
#     "session_id":   "...",
#     "cwd":          "/path/to/repo",
#     "tool_name":    "Bash",
#     "tool_input":   { "command": "gh pr create --title ...", "description": "..." },
#     "tool_response":{ "stdout":  "https://github.com/o/r/pull/123\n...", "stderr": "..." }
#   }
#
# We don't trust exit code alone (`gh pr create --dry-run` succeeds without
# opening anything), so we require a real PR URL in stdout.
#
# The actual CI fetch runs detached so this hook returns instantly.
#
# Wired up by install.sh under settings.json -> hooks.PostToolUse.

set -uo pipefail

INPUT=$(cat)

# Ignore everything except Bash tool calls.
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$TOOL" != "Bash" ] && exit 0

# Only react to `gh pr create`. Match loosely so flag order, description, etc.
# don't trip us up. The literal "gh pr create" substring is sufficient — we
# don't want to over-engineer a regex that might miss future invocations.
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
case "$CMD" in
    *"gh pr create"*) ;;
    *) exit 0 ;;
esac

# Require a github.com PR URL in stdout — proves the create actually opened
# a PR (not a --dry-run, not a --help).
STDOUT=$(printf '%s' "$INPUT" | jq -r '.tool_response.stdout // ""' 2>/dev/null)
if ! printf '%s' "$STDOUT" | grep -qE 'https://github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+'; then
    exit 0
fi

# Resolve the working directory the create ran in. Hook payload's `cwd` is
# the canonical answer; fall back to `workspace.current_dir` for older Claude
# Code versions.
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // .workspace.current_dir // ""' 2>/dev/null)
[ -z "$CWD" ] && exit 0
[ ! -d "$CWD" ] && exit 0

cd "$CWD" 2>/dev/null || exit 0

BRANCH=$(git branch --show-current 2>/dev/null) || exit 0
[ -z "$BRANCH" ] && exit 0

# Same repo-id derivation statusline.sh uses, so we hit the same cache file.
REPO_ID=$(git config --get remote.origin.url 2>/dev/null \
            | sed -E 's#.*[:/]([^/:]+/[^/]+)(\.git)?$#\1#; s#\.git$##')
[ -z "$REPO_ID" ] && exit 0

CACHE_KEY="${REPO_ID//\//_}__${BRANCH//\//_}"
CACHE="$HOME/.claude/cache/ci/${CACHE_KEY}.json"

mkdir -p "$(dirname "$CACHE")" 2>/dev/null

# Bust any in-flight lock — the just-created PR is what we explicitly want
# to see, not whatever was being fetched a moment ago.
rmdir "${CACHE}.lock" 2>/dev/null || true

# Detached, fully backgrounded — must not hold up Claude's tool-response
# pipeline. setsid so the fetch survives the hook process exiting; nohup so
# it ignores SIGHUP if the parent terminal closes.
if command -v setsid >/dev/null 2>&1; then
    setsid -f "$HOME/.claude/ci-fetch.sh" "$CWD" "$CACHE" </dev/null >/dev/null 2>&1 &
else
    # macOS doesn't ship setsid by default; rely on (...&) + disown.
    ( nohup "$HOME/.claude/ci-fetch.sh" "$CWD" "$CACHE" </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
fi

exit 0
