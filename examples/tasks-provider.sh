#!/usr/bin/env bash
# muxclaude — example tasks provider for the sidebar.
#
# statusline.sh calls whatever you set in $MUXCLAUDE_TASKS_CMD and treats its
# stdout as a task list. Each line must be:
#
#     <status>\t<title>
#
# where <status> is one of:
#
#     pending      —  shown as:  "  Title"
#     in_progress  —  shown as:  "→ Title"   (green)
#     completed    —  shown as:  "✓ Title"   (dim)
#     blocked      —  shown as:  "✗ Title"   (red)
#
# Anything else is ignored. A non-zero exit silently disables the section.
#
# Arguments your command receives:
#     $1  project name  (basename of repo root, or current dir)
#     $2  working dir   (absolute path)
#
# To wire it up, point statusline.sh at this script:
#     export MUXCLAUDE_TASKS_CMD="$HOME/.claude/muxclaude-tasks.sh"
#
# Below are several worked examples — uncomment ONE and adapt to your tools.

set -u

PROJECT="${1:-}"
WORKING_DIR="${2:-$PWD}"

# -----------------------------------------------------------------------------
# EXAMPLE 1 — Static demo (uncomment to confirm the pipeline works)
# -----------------------------------------------------------------------------
# printf 'in_progress\tWire up the sidebar\n'
# printf 'pending\tWrite docs\n'
# printf 'completed\tInitial scaffold\n'
# printf 'blocked\tWaiting on review\n'
# exit 0

# -----------------------------------------------------------------------------
# EXAMPLE 2 — Plain-text TODO file at .tasks/TODO.md inside the repo
# -----------------------------------------------------------------------------
# Format:
#     - [ ] pending task
#     - [x] completed task
#     - [>] in_progress task
#     - [!] blocked task
#
# todo_file="$WORKING_DIR/.tasks/TODO.md"
# [ -r "$todo_file" ] || exit 0
# while IFS= read -r line; do
#   case "$line" in
#     "- [x] "*) printf 'completed\t%s\n'   "${line#- [x] }" ;;
#     "- [>] "*) printf 'in_progress\t%s\n' "${line#- [>] }" ;;
#     "- [!] "*) printf 'blocked\t%s\n'     "${line#- [!] }" ;;
#     "- [ ] "*) printf 'pending\t%s\n'     "${line#- [ ] }" ;;
#   esac
# done < "$todo_file"
# exit 0

# -----------------------------------------------------------------------------
# EXAMPLE 3 — GitHub issues assigned to you on the current repo
# -----------------------------------------------------------------------------
# Requires `gh` and a current branch. Issues with the "blocked" label show as
# blocked; otherwise pending. (Customise to your label scheme.)
#
# command -v gh >/dev/null || exit 0
# git -C "$WORKING_DIR" rev-parse --git-dir >/dev/null 2>&1 || exit 0
# gh issue list \
#   --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
#   --assignee "@me" --state open --json title,labels \
#   --jq '.[] | (if any(.labels[]?.name; . == "blocked") then "blocked" else "pending" end) + "\t" + .title' \
#   2>/dev/null
# exit 0

# -----------------------------------------------------------------------------
# EXAMPLE 4 — Custom CLI (replace with whatever your kanban tool exposes)
# -----------------------------------------------------------------------------
# Many task CLIs already produce TSV-friendly output. Adapt with awk:
#
# my-todo-cli list --project "$PROJECT" --status open \
#   | awk -F'|' '{print $2 "\t" $3}'
# exit 0

# Default: emit nothing (sidebar Tasks section will be hidden).
exit 0
