#!/usr/bin/env bash
# muxclaude — example Claude Code Stop hook.
#
# When Claude tries to end its turn, this hook checks your task source for
# outstanding work and rejects the Stop *only when there is some*. The check
# happens inside the hook so the conversation history stays clean: if there's
# nothing to do, Claude just stops — no redundant "go look at your tracker"
# round-trip.
#
# Reuses the same plug-in the sidebar uses: MUXCLAUDE_TASKS_CMD is invoked
# as `<cmd> <project> <working_dir>` and is expected to print zero or more
# `<status>\t<title>` rows on stdout, where <status> is one of:
#     pending | in_progress | completed | blocked
#
# Behaviour
#   - On the FIRST stop in a turn, we run MUXCLAUDE_TASKS_CMD. If it returns
#     any pending or in_progress rows we emit a "block" decision and the
#     model continues. blocked rows are deliberately ignored — they can't
#     be progressed, so blocking on them would create a Stop loop.
#   - On a recursive Stop in the same turn (stop_hook_active=true), we
#     no-op so Claude can always actually finish.
#
# Fails open: any tooling error (no MUXCLAUDE_TASKS_CMD, jq missing, command
# error, …) lets the Stop succeed. Better to lose the nudge than create a
# hard-to-debug "Claude won't stop" situation.

set -uo pipefail

INPUT=$(cat)

# Already inside a stop-hook chain — don't recurse.
STOP_HOOK_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# Need a task source. MUXCLAUDE_TASKS_CMD may be `path arg1 arg2`; the
# executable is just the first word.
TASKS_CMD="${MUXCLAUDE_TASKS_CMD:-}"
[ -z "$TASKS_CMD" ] && exit 0
[ -x "${TASKS_CMD%% *}" ] || exit 0

# Resolve the working directory the Stop fired in.
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // .workspace.current_dir // ""' 2>/dev/null)
[ -z "$CWD" ] || [ ! -d "$CWD" ] && exit 0
cd "$CWD" 2>/dev/null || exit 0

# Same project-name derivation statusline.sh uses (worktree-aware), so the
# scope your provider keys off matches the sidebar's view.
PROJECT_NAME="${CWD##*/}"
if git rev-parse --git-dir > /dev/null 2>&1; then
  GIT_DIR_ABS=$(cd "$(git rev-parse --git-dir)" && pwd)
  GIT_COMMON_ABS=$(cd "$(git rev-parse --git-common-dir)" && pwd)
  if [ "$GIT_DIR_ABS" != "$GIT_COMMON_ABS" ]; then
    MAIN_REPO="${GIT_COMMON_ABS%/.git}"
    PROJECT_NAME="${MAIN_REPO##*/}"
  fi
fi

# shellcheck disable=SC2086
OUTPUT=$($TASKS_CMD "$PROJECT_NAME" "$CWD" 2>/dev/null) || exit 0
[ -z "$OUTPUT" ] && exit 0

# Count pending + in_progress only. blocked tasks deliberately don't trigger
# a block — they can't be progressed, so blocking on them would create a
# Stop loop with no exit.
COUNT=$(printf '%s\n' "$OUTPUT" | awk -F'\t' '$1=="pending" || $1=="in_progress"' | wc -l | tr -d ' ')
[ "$COUNT" = "0" ] && exit 0

REASON="${COUNT} pending/in-progress task(s) outstanding in this scope. Continue with the next runnable item, or mark them complete/cancelled if no longer applicable."

jq -nc --arg reason "$REASON" '{decision:"block", reason:$reason}'
