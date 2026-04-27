#!/bin/bash
# muxclaude — Claude Code SessionEnd hook.
#
# Kills any tmux pane tagged with @claude_sidebar=1 in the same window where
# Claude Code is running. Scoped to the current window so other windows'
# sidebars survive.
#
# Wired up by install.sh under settings.json -> hooks.SessionEnd.

[ -z "${TMUX_PANE:-}" ] && exit 0

WIN=$(tmux display -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)
[ -z "$WIN" ] && exit 0

tmux list-panes -t "$WIN" -F '#{pane_id} #{@claude_sidebar}' 2>/dev/null \
  | awk '$2=="1"{print $1}' \
  | while read -r pane; do
      [ -n "$pane" ] && tmux kill-pane -t "$pane" 2>/dev/null
    done

exit 0
