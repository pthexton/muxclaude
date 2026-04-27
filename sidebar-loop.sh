#!/bin/bash
# Render the muxclaude sidebar for whichever Claude session owns the current
# tmux window. statusline.sh publishes the active session's sidebar file path
# on the window option @claude_sidebar_file; we re-read it each tick so the
# sidebar follows the most recently active session in this window.
#
# Flicker-free redraw: we only repaint when the file's mtime+size changes
# (or the pane is resized), and we do it via cursor-home + erase-to-EOL +
# erase-below rather than a full clear, so unchanged pixels aren't blanked
# first.

DEFAULT="$HOME/.claude/sidebar.txt"
last_sig=""
last_size_sig=""

# Initial clear once, so previous pane contents don't show through.
printf '\033[2J\033[H'

while :; do
  FILE=$(tmux show-options -w -q -v @claude_sidebar_file 2>/dev/null)
  [ -z "$FILE" ] && FILE="$DEFAULT"

  # Force a repaint if the pane itself was resized (otherwise a smaller
  # sidebar with stale long lines would remain until the source file changes).
  size_sig=$(tmux display -p '#{pane_width}x#{pane_height}' 2>/dev/null)

  if [ -r "$FILE" ]; then
    cur_sig=$(stat -f '%m %z' "$FILE" 2>/dev/null)
  else
    cur_sig="-"
  fi

  if [ "$cur_sig|$size_sig" != "$last_sig|$last_size_sig" ]; then
    printf '\033[H'
    # Append \033[K (erase-to-EOL) to each line so a shorter new line
    # doesn't leave trailing characters from the previous render.
    [ -r "$FILE" ] && awk '{printf "%s\033[K\n", $0}' "$FILE"
    # Clear any rows below (the previous render may have been taller).
    printf '\033[0J'
    last_sig="$cur_sig"
    last_size_sig="$size_sig"
  fi
  sleep 1
done
