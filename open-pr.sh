#!/usr/bin/env bash
# muxclaude — F6 open-PR-in-browser action.
#
# Opens the GitHub PR for the current branch in the default browser, with a
# tmux floating popup that confirms what's happening (or what failed) and
# auto-closes after 5 seconds.
#
# Bound to F6 via tmux/muxclaude.tmux.conf (gated to Claude windows).
# Resolves the working directory by:
#   1. Reading @claude_ci_dir (set by statusline.sh) if present — this is the
#      directory of the focused Claude Code session, which is almost always
#      what the user means.
#   2. Falling back to the focused pane's current path otherwise.
#
# All status — success path and every failure path — surfaces in the popup
# rather than the slim tmux status line, because the popup is unmissable
# even when tmux is busy doing something else.
#
# Requires: git, gh, tmux.

WIN_ID=$(tmux display -p '#{window_id}' 2>/dev/null) || exit 0

# Reusable helper: show a one-shot popup with a coloured headline and body
# line, auto-close after 5s. Call sites pass already-formatted strings.
show_popup() {
    local headline="$1" body="$2"
    local script
    script=$(mktemp -t muxclaude-f6-open-pr) || return
    {
        echo '#!/bin/bash'
        printf 'HEADLINE=%q\n' "$headline"
        printf 'BODY=%q\n'     "$body"
        printf 'SELF=%q\n'     "$script"
        cat <<'INNER'
trap 'rm -f "$SELF"' EXIT
printf '%b\n\n' "$HEADLINE"
[ -n "$BODY" ] && printf '%b\n' "$BODY"
sleep 5
INNER
    } > "$script"
    chmod +x "$script"
    ( tmux display-popup -E -h 7 -w 78 -T " PR " "$script" ) &
}

DIR=$(tmux show-options -w -q -v -t "$WIN_ID" @claude_ci_dir 2>/dev/null)
if [ -z "$DIR" ]; then
    DIR=$(tmux display -p '#{pane_current_path}' 2>/dev/null)
fi

if [ -z "$DIR" ]; then
    show_popup "\033[31m✗ Could not determine working directory.\033[0m" ""
    exit 0
fi

if ! git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    show_popup "\033[31m✗ Not a git repository\033[0m" "$(basename "$DIR")"
    exit 0
fi

BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && BRANCH="?"

# `gh pr view` returns non-zero when no PR is open for the current branch.
# Capture stderr so we can distinguish "no PR" from auth/network failures.
PR_OUTPUT=$(cd "$DIR" && gh pr view --json url -q .url 2>&1)
PR_EXIT=$?

if [ "$PR_EXIT" -ne 0 ] || [ -z "$PR_OUTPUT" ]; then
    if printf '%s' "$PR_OUTPUT" | grep -qiE 'no pull requests|no associated pull request'; then
        show_popup "\033[33m◔ No open PR for branch \033[37m${BRANCH}\033[0m" ""
    else
        # Truncate gh's error so it fits the popup width.
        first_line=$(printf '%s' "$PR_OUTPUT" | head -n 1 | cut -c 1-72)
        show_popup "\033[31m✗ gh pr view failed\033[0m" "${first_line}"
    fi
    exit 0
fi

show_popup "\033[32m→ Opening PR\033[0m for branch \033[33m${BRANCH}\033[0m" "${PR_OUTPUT}"

# macOS uses /usr/bin/open; Linux falls back to xdg-open.
if [ "$(uname -s)" = "Darwin" ]; then
    /usr/bin/open "$PR_OUTPUT"
elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$PR_OUTPUT" >/dev/null 2>&1
fi
exit 0
