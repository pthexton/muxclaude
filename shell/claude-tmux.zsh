# muxclaude — tmux-aware claude() shell function (zsh).
#
# Sourced into ~/.zshrc by install.sh. When you run `claude`:
#   * If you're already inside tmux, just exec the real claude binary.
#   * Otherwise, start a dedicated tmux session that runs claude. When claude
#     exits, the session exits too. Inside the session, statusline.sh
#     auto-spawns a sidebar pane.
#
# Why a dedicated session? It guarantees claude *and* the sidebar share a
# tmux window from the very first render — no manual "tmux new" step.
#
# Override the session name template via $MUXCLAUDE_SESSION_NAME. The default
# uses $$ so two parallel `claude` invocations can't collide.

claude() {
  if [[ -z "$TMUX" ]]; then
    local sess="${MUXCLAUDE_SESSION_NAME:-claude-$$}"
    # ${(q)@} is zsh's quote-for-shell expansion — preserves args with spaces.
    tmux new-session -s "$sess" "command claude ${(q)@}"
  else
    command claude "$@"
  fi
}
