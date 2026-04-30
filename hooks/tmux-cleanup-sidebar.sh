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

# Tell statusline.sh not to respawn the sidebar during teardown. A statusline
# tick can fire after this hook but before claude actually exits — without the
# marker, that tick would find no sidebar pane and immediately spawn a fresh
# one with nothing left to clean it up. statusline.sh only honours the marker
# for ~10s so a later session in the same window isn't permanently blocked.
tmux set-option -w -t "$WIN" @claude_sidebar_disabled_at "$(date +%s)" 2>/dev/null

tmux list-panes -t "$WIN" -F '#{pane_id} #{@claude_sidebar}' 2>/dev/null \
  | awk '$2=="1"{print $1}' \
  | while read -r pane; do
      [ -n "$pane" ] && tmux kill-pane -t "$pane" 2>/dev/null
    done

exit 0
