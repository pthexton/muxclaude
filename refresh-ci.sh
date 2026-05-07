#!/usr/bin/env bash
# muxclaude — F5 manual CI refresh trigger.
#
# Bound to F5 via tmux/muxclaude.tmux.conf when the active window is a Claude
# window (window has @claude_ci_cache set by statusline.sh). Reads the working
# dir + cache path that statusline.sh publishes on @claude_ci_dir and
# @claude_ci_cache, then runs ci-fetch.sh inside a tmux popup so the user
# gets visible confirmation (refreshing → done → summary, then auto-close).
#
# Why this exists: the cache-staleness logic in statusline.sh treats any
# terminal CI state at the current commit as final and never auto-refreshes
# (so we don't burn API quota on repos whose CI is done). F5 forces a refetch
# for cases like a flaky job that's been re-run, or a check that was added
# later by an external workflow.
#
# Requires: git, gh, jq, tmux.

WIN_ID=$(tmux display -p '#{window_id}' 2>/dev/null) || exit 0
DIR=$(tmux   show-options -w -q -v -t "$WIN_ID" @claude_ci_dir   2>/dev/null)
CACHE=$(tmux show-options -w -q -v -t "$WIN_ID" @claude_ci_cache 2>/dev/null)

if [ -z "$DIR" ] || [ -z "$CACHE" ]; then
  tmux display-message -d 1500 "F5: no Claude CI context registered" 2>/dev/null
  exit 0
fi

BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && BRANCH="?"

# Force a refetch by busting the lock if it's there (the user explicitly
# asked for fresh data — don't make them wait on a coincident background run).
rmdir "${CACHE}.lock" 2>/dev/null || true

# Build the popup's script on disk; printf %q gives shell-safe escaping for
# paths and branch names so we don't have to think about quoting.
SCRIPT=$(mktemp -t muxclaude-f5-refresh-ci) || exit 0
{
    echo '#!/bin/bash'
    printf 'BRANCH=%q\n' "$BRANCH"
    printf 'DIR=%q\n'    "$DIR"
    printf 'CACHE=%q\n'  "$CACHE"
    printf 'SELF=%q\n'   "$SCRIPT"
    cat <<'INNER'
trap 'rm -f "$SELF"' EXIT
printf '\033[36m⟳ Refreshing CI\033[0m for branch \033[33m%s\033[0m...\n\n' "$BRANCH"
"$HOME/.claude/ci-fetch.sh" "$DIR" "$CACHE" >/dev/null 2>&1
RC=$?
if [ $RC -eq 0 ] && [ -r "$CACHE" ]; then
    PR_NUM=$(jq -r '.pr.number // ""' "$CACHE" 2>/dev/null)
    if [ -n "$PR_NUM" ]; then
        PASS=$(jq    '[.checks[]|select(.bucket=="pass")]    |length' "$CACHE" 2>/dev/null)
        FAIL=$(jq    '[.checks[]|select(.bucket=="fail")]    |length' "$CACHE" 2>/dev/null)
        PEND=$(jq    '[.checks[]|select(.bucket=="pending")] |length' "$CACHE" 2>/dev/null)
        printf '\033[32m✓ Done.\033[0m  PR #%s  ' "$PR_NUM"
        printf '\033[32m%s pass\033[0m  \033[31m%s fail\033[0m  \033[33m%s pending\033[0m\n' \
            "$PASS" "$FAIL" "$PEND"
    else
        printf '\033[33m◔ No PR yet for this branch.\033[0m\n'
    fi
else
    printf '\033[31m✗ Fetch failed.\033[0m\n'
fi
sleep 4
INNER
} > "$SCRIPT"
chmod +x "$SCRIPT"

# Background the popup so the keybinding returns immediately.
( tmux display-popup -E -h 7 -w 78 -T " CI " "$SCRIPT" ) &
exit 0
