#!/usr/bin/env bash
# muxclaude installer.
#
# Copies muxclaude scripts into ~/.claude, patches ~/.claude/settings.json so
# Claude Code uses them, and adds the claude() tmux wrapper to ~/.zshrc.
#
# Idempotent: re-running updates files in place and won't double-add entries.
# Backups: any pre-existing file we replace is saved with a timestamp suffix.
#
# Flags:
#   --prefix DIR        Install dir (default: $HOME/.claude)
#   --with-stop-hook    Install the example Stop hook that nudges Claude to
#                       check your task tracker before ending its turn. Only
#                       useful if you've wired up MUXCLAUDE_TASKS_CMD; off by
#                       default.
#   --no-zshrc          Don't touch ~/.zshrc (skip the claude() function)
#   --tasks-cmd PATH    Set MUXCLAUDE_TASKS_CMD in the .zshrc snippet to PATH
#   --dry-run           Show what would change; don't write anything
#   -h, --help          Show this help

set -euo pipefail

# --- Locate this script & the source tree -----------------------------------
SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# --- Defaults ----------------------------------------------------------------
PREFIX="$HOME/.claude"
INSTALL_STOP_HOOK=0
EDIT_ZSHRC=1
TASKS_CMD=""
DRY_RUN=0
TS=$(date +%Y%m%d-%H%M%S)

usage() { awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"; }

# --- Args --------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)          PREFIX="$2"; shift 2 ;;
    --with-stop-hook)  INSTALL_STOP_HOOK=1; shift ;;
    --no-zshrc)        EDIT_ZSHRC=0; shift ;;
    --tasks-cmd)       TASKS_CMD="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage; exit 2 ;;
  esac
done

say()  { printf '\033[36m›\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
do_cmd() {
  if [ "$DRY_RUN" -eq 1 ]; then printf '  (dry-run) %s\n' "$*"
  else eval "$@"
  fi
}

# --- Preflight ---------------------------------------------------------------
command -v jq   >/dev/null || { warn "jq not found — install it (brew install jq) and re-run."; exit 1; }
command -v tmux >/dev/null || warn "tmux not found — sidebar features won't work until you install it."
command -v gh   >/dev/null || warn "gh not found — the CI section + F5/F6 popups will stay hidden until you install it (brew install gh)."

say "Source:  $SRC_DIR"
say "Prefix:  $PREFIX"
[ "$DRY_RUN" -eq 1 ] && say "Mode:    dry-run (no writes)"

mkdir -p "$PREFIX/hooks"

# --- Copy scripts ------------------------------------------------------------
copy_with_backup() {
  local src=$1 dst=$2
  if [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then
    do_cmd "cp -p '$dst' '$dst.bak.$TS'"
    say "Backed up existing $(basename "$dst") -> $(basename "$dst").bak.$TS"
  fi
  do_cmd "install -m 0755 '$src' '$dst'"
}

say "Installing scripts…"
copy_with_backup "$SRC_DIR/statusline.sh"                  "$PREFIX/statusline.sh"
copy_with_backup "$SRC_DIR/sidebar-loop.sh"                "$PREFIX/sidebar-loop.sh"
copy_with_backup "$SRC_DIR/ci-fetch.sh"                    "$PREFIX/ci-fetch.sh"
copy_with_backup "$SRC_DIR/refresh-ci.sh"                  "$PREFIX/refresh-ci.sh"
copy_with_backup "$SRC_DIR/open-pr.sh"                     "$PREFIX/open-pr.sh"
copy_with_backup "$SRC_DIR/hooks/tmux-cleanup-sidebar.sh"  "$PREFIX/hooks/tmux-cleanup-sidebar.sh"
copy_with_backup "$SRC_DIR/hooks/pr-created-refresh-ci.sh" "$PREFIX/hooks/pr-created-refresh-ci.sh"

# tmux key bindings example — users source-file this from their own tmux.conf.
mkdir -p "$PREFIX/tmux"
do_cmd "install -m 0644 '$SRC_DIR/tmux/muxclaude.tmux.conf' '$PREFIX/tmux/muxclaude.tmux.conf'"

# Always stage the Stop-hook template so users who later wire up tasks can
# enable it just by re-running with --with-stop-hook (or by editing settings).
copy_with_backup "$SRC_DIR/hooks/stop-continue-tasks.sh" "$PREFIX/hooks/stop-continue-tasks.sh"

# Install the example tasks provider only if the user doesn't already have one.
TASKS_PROVIDER_DST="$PREFIX/muxclaude-tasks.sh"
if [ ! -e "$TASKS_PROVIDER_DST" ]; then
  do_cmd "install -m 0755 '$SRC_DIR/examples/tasks-provider.sh' '$TASKS_PROVIDER_DST'"
  say "Installed example tasks provider at $TASKS_PROVIDER_DST (edit to enable)."
else
  say "Existing tasks provider kept at $TASKS_PROVIDER_DST."
fi

# --- Patch settings.json -----------------------------------------------------
SETTINGS="$PREFIX/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

say "Patching $SETTINGS …"
if [ "$DRY_RUN" -eq 0 ]; then
  cp -p "$SETTINGS" "$SETTINGS.bak.$TS"
fi

# Build the new settings JSON. We:
#   * set statusLine to point at our script,
#   * remove any prior muxclaude hook entries (matched by command path) so
#     re-running the installer doesn't accumulate duplicates,
#   * append our hook entries.
SL_CMD="$PREFIX/statusline.sh"
CLEANUP_CMD="$PREFIX/hooks/tmux-cleanup-sidebar.sh"
STOP_CMD="$PREFIX/hooks/stop-continue-tasks.sh"
PRCI_CMD="$PREFIX/hooks/pr-created-refresh-ci.sh"

NEW_JSON=$(jq \
  --arg sl       "$SL_CMD" \
  --arg cleanup  "$CLEANUP_CMD" \
  --arg stop     "$STOP_CMD" \
  --arg prci     "$PRCI_CMD" \
  --argjson installStop "$INSTALL_STOP_HOOK" '
    # statusLine
    .statusLine = { type: "command", command: $sl }

    # hooks bucket exists
    | .hooks = (.hooks // {})

    # SessionEnd: drop any muxclaude entry, then append fresh
    | .hooks.SessionEnd = (
        ((.hooks.SessionEnd // []) | map(
          select(
            (.hooks // []) | map(.command // "") | any(. == $cleanup) | not
          )
        ))
        + [{ hooks: [{ type: "command", command: $cleanup, timeout: 5 }] }]
      )

    # PostToolUse: drop any muxclaude entry, then append fresh. The hook
    # script self-filters on tool_name=="Bash" + the "gh pr create" substring,
    # so a global registration here is a no-op for every other tool call.
    | .hooks.PostToolUse = (
        ((.hooks.PostToolUse // []) | map(
          select(
            (.hooks // []) | map(.command // "") | any(. == $prci) | not
          )
        ))
        + [{ hooks: [{ type: "command", command: $prci, timeout: 5 }] }]
      )

    # Stop: always drop a previous muxclaude entry; re-add only if requested
    | .hooks.Stop = (
        ((.hooks.Stop // []) | map(
          select(
            (.hooks // []) | map(.command // "") | any(. == $stop) | not
          )
        ))
        + ( if $installStop == 1
            then [{ hooks: [{ type: "command", command: $stop, timeout: 10,
                              statusMessage: "Checking for remaining task work" }] }]
            else [] end )
      )

    # Tidy: drop empty arrays so the file stays clean
    | .hooks |= with_entries(select(.value | length > 0))
  ' "$SETTINGS")

if [ "$DRY_RUN" -eq 1 ]; then
  echo "  (dry-run) settings.json would become:"
  echo "$NEW_JSON" | jq . | sed 's/^/    /'
else
  printf '%s\n' "$NEW_JSON" | jq . > "$SETTINGS"
  say "settings.json updated (backup: $(basename "$SETTINGS").bak.$TS)."
fi

# --- Patch ~/.zshrc ----------------------------------------------------------
if [ "$EDIT_ZSHRC" -eq 1 ]; then
  ZSHRC="$HOME/.zshrc"
  MARK_BEGIN="# >>> muxclaude >>>"
  MARK_END="# <<< muxclaude <<<"

  # Build the snippet. If the user already has a top-level claude() function in
  # their .zshrc outside our markers, we don't try to delete it — we'll warn so
  # they can resolve the conflict.
  SNIPPET=$(cat <<EOF
$MARK_BEGIN
# Managed by muxclaude install.sh — re-running the installer overwrites this block.
EOF
)
  if [ -n "$TASKS_CMD" ]; then
    SNIPPET+=$'\n'"export MUXCLAUDE_TASKS_CMD=\"$TASKS_CMD\""
  fi
  SNIPPET+=$'\n'"# Source the tmux-aware claude() function."$'\n'
  SNIPPET+="[ -r \"$PREFIX/shell/claude-tmux.zsh\" ] && source \"$PREFIX/shell/claude-tmux.zsh\""$'\n'
  SNIPPET+="$MARK_END"

  # Stage the function file alongside the rest of muxclaude, so the snippet has
  # something to source.
  mkdir -p "$PREFIX/shell"
  do_cmd "install -m 0644 '$SRC_DIR/shell/claude-tmux.zsh' '$PREFIX/shell/claude-tmux.zsh'"

  if [ -f "$ZSHRC" ] && grep -q "$MARK_BEGIN" "$ZSHRC"; then
    say "Updating muxclaude block in $ZSHRC …"
    if [ "$DRY_RUN" -eq 0 ]; then
      cp -p "$ZSHRC" "$ZSHRC.bak.$TS"
      # Strip the existing block (BSD awk can't take multi-line -v values, so
      # we delete here and append the new snippet from the shell).
      awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        $0 == b { in_block = 1; next }
        in_block && $0 == e { in_block = 0; next }
        !in_block { print }
      ' "$ZSHRC" > "$ZSHRC.tmp"
      # Trim trailing blank lines left over from the removed block, then append.
      awk 'NF || keep { keep=1; lines[++n]=$0 } END { for (i=n; i>=1; i--) if (lines[i] == "") n--; else break; for (i=1; i<=n; i++) print lines[i] }' "$ZSHRC.tmp" > "$ZSHRC.tmp2"
      mv "$ZSHRC.tmp2" "$ZSHRC.tmp"
      printf '\n%s\n' "$SNIPPET" >> "$ZSHRC.tmp"
      mv "$ZSHRC.tmp" "$ZSHRC"
    fi
  else
    say "Appending muxclaude block to $ZSHRC …"
    if [ "$DRY_RUN" -eq 0 ]; then
      [ -f "$ZSHRC" ] && cp -p "$ZSHRC" "$ZSHRC.bak.$TS"
      printf '\n%s\n' "$SNIPPET" >> "$ZSHRC"
    fi
  fi

  # Warn about a foreign claude() definition that would shadow ours.
  if [ -f "$ZSHRC" ] && grep -nE '^[[:space:]]*claude[[:space:]]*\(\)' "$ZSHRC" \
       | grep -v "$PREFIX/shell/claude-tmux.zsh" >/dev/null 2>&1; then
    if ! awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
      $0 == b { in_block = 1 }
      in_block && /^[[:space:]]*claude[[:space:]]*\(\)/ { found_in_block = 1 }
      $0 == e { in_block = 0 }
      END { exit found_in_block ? 0 : 1 }
    ' "$ZSHRC"; then
      warn "An existing claude() definition was found in $ZSHRC outside the muxclaude block — it may shadow ours. Review and remove if desired."
    fi
  fi
fi

# --- Done --------------------------------------------------------------------
say "Done."
cat <<EOF

Next steps:
  1. Reload your shell:                source ~/.zshrc
  2. (Optional) plug in a task source: edit $PREFIX/muxclaude-tasks.sh
                                       and \`export MUXCLAUDE_TASKS_CMD=$PREFIX/muxclaude-tasks.sh\`
                                       (or re-run install.sh with --tasks-cmd).
  3. (Optional) wire up F5/F6 popups in tmux. Add this to your ~/.tmux.conf:
       source-file $PREFIX/tmux/muxclaude.tmux.conf
     Then \`tmux source-file ~/.tmux.conf\`. F5 force-refreshes CI, F6 opens
     the PR for the active branch — both shown via tmux popups.
  4. (Optional) if you wired up a task source, you can also enable a Stop
     hook that re-uses MUXCLAUDE_TASKS_CMD: it checks your tracker on every
     Stop and only blocks (telling Claude to keep going) when there is
     pending or in_progress work — otherwise Claude stops cleanly:
       re-run install.sh --with-stop-hook
  5. Run:                               claude

  Inside tmux you'll get a sidebar pane on the right; outside you'll get a
  two-line status. See $SRC_DIR/README.md for the full input-field reference.
EOF
