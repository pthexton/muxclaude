#!/usr/bin/env bash
# muxclaude — example Claude Code Stop hook.
#
# When Claude tries to end its turn, this hook nudges it to first check
# whatever task tracker you use (Linear, Jira, swift-todo-manager, a local
# kanban file, etc.) and continue if there is more runnable work.
#
# Behaviour
#   - On the FIRST stop in a turn, we emit a "block" decision with a reason
#     telling Claude to look for outstanding work. Claude will read the reason
#     and decide whether to keep going.
#   - On the SECOND stop in the same turn (stop_hook_active=true), we no-op
#     so Claude can actually finish.
#
# Customise REASON below to match the tracker you use. If you don't use any
# tracker, you probably want to remove this hook from settings.json
# entirely — it adds latency for no benefit.

set -euo pipefail

INPUT=$(cat)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active')

if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# EDIT ME: replace with a sentence that names *your* task source.
# Examples:
#   "check Linear for any open tickets assigned to me on this branch and continue"
#   "look at .tasks/TODO.md — if anything is pending or in_progress, keep going"
#   "check the swift-todo-manager mcp for tasks to perform next and continue"
REASON="check your task tracker for tasks to perform next and continue unless unable to"

printf '%s\n' "{\"decision\":\"block\",\"reason\":\"${REASON}\"}"
