#!/bin/bash
# =============================================================================
# muxclaude statusline
# -----------------------------------------------------------------------------
# Renders Claude Code's status line. When run inside tmux, also maintains a
# right-side "sidebar" pane with richer info (usage bars, workspace, tasks).
# When run outside tmux, prints a compact two-line status with task columns.
#
# Claude Code invokes this script on every status refresh, piping a JSON
# document to stdin. Below is the full set of fields you can read and use to
# extend or tune what gets shown. Anything not used here is fair game for
# customisation.
#
# JSON INPUT FIELDS  (all paths are jq expressions; some may be absent)
# -----------------------------------------------------------------------------
#   .session_id                          string   stable id for this session
#   .transcript_path                     string   path to the session JSONL
#                                                 (handy as a per-session anchor)
#   .cwd                                 string   shell cwd at status time
#   .version                             string   Claude Code version
#   .output_style.name                   string   current output style
#
#   .model.id                            string   e.g. "claude-opus-4-7"
#   .model.display_name                  string   short label for UI
#
#   .workspace.current_dir               string   active dir (may equal .cwd)
#   .workspace.project_dir               string   first dir Claude was started in
#   .workspace.added_dirs[]              strings  /add-dir extra roots
#
#   .cost.total_cost_usd                 number   running session cost
#   .cost.total_duration_ms              number   wall time of session
#   .cost.total_api_duration_ms          number   time spent in API calls
#   .cost.total_lines_added              number   diffs applied this session
#   .cost.total_lines_removed            number
#
#   .context_window.used_tokens          number   current prompt size
#   .context_window.max_tokens           number
#   .context_window.used_percentage      number   0..100 (may be float)
#
#   .rate_limits.five_hour.used_percentage      number 0..100
#   .rate_limits.five_hour.resets_at            number unix epoch seconds
#   .rate_limits.seven_day.used_percentage      number 0..100
#   .rate_limits.seven_day.resets_at            number unix epoch seconds
#
# A complete sample is captured to $MUXCLAUDE_DEBUG_INPUT (if set) every tick,
# which is the easiest way to discover any new fields Anthropic adds:
#
#     export MUXCLAUDE_DEBUG_INPUT=$HOME/.claude/last-statusline-input.json
#
# CUSTOMISING THE TASK LIST
# -----------------------------------------------------------------------------
# The "Tasks" section in the sidebar (and the column block in non-tmux mode)
# is populated by an external command of your choosing. Set:
#
#     export MUXCLAUDE_TASKS_CMD="/path/to/your/script"
#
# Your script will be invoked with two arguments:
#
#     $1  project name  (basename of repo root or current dir)
#     $2  working dir   (absolute path)
#
# It must print zero or more lines on stdout, each line being:
#
#     <status>\t<title>
#
# where <status> is one of: pending | in_progress | completed | blocked
# Anything else is ignored. A non-zero exit silently disables the section.
#
# See examples/tasks-provider.sh in this repo for a stub you can copy.
# =============================================================================

set -u

# --- Read input --------------------------------------------------------------
input=$(cat)

# Optional debug capture — useful for discovering new fields.
if [ -n "${MUXCLAUDE_DEBUG_INPUT:-}" ]; then
  printf '%s' "$input" > "$MUXCLAUDE_DEBUG_INPUT" 2>/dev/null || true
fi

MODEL=$(echo "$input"          | jq -r '.model.display_name // .model.id // "?"')
DIR=$(echo "$input"            | jq -r '.workspace.current_dir // .cwd // empty')
PROJECT_DIR=$(echo "$input"    | jq -r '.workspace.project_dir // empty')
ADDED_DIRS=$(echo "$input"     | jq -r '.workspace.added_dirs[]? // empty')
COST=$(echo "$input"           | jq -r '.cost.total_cost_usd // 0')
CTX_PCT=$(echo "$input"        | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
DURATION_MS=$(echo "$input"    | jq -r '.cost.total_duration_ms // 0')
TRANSCRIPT=$(echo "$input"     | jq -r '.transcript_path // empty')
FIVE_H_PCT=$(echo "$input"     | jq -r '.rate_limits.five_hour.used_percentage // empty' | cut -d. -f1)
FIVE_H_RESETS=$(echo "$input"  | jq -r '.rate_limits.five_hour.resets_at // empty')
SEVEN_D_PCT=$(echo "$input"    | jq -r '.rate_limits.seven_day.used_percentage // empty' | cut -d. -f1)
SEVEN_D_RESETS=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# --- Colour palette ----------------------------------------------------------
CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'
MAGENTA='\033[35m'; BLUE='\033[34m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# --- Helpers -----------------------------------------------------------------
fmt_remaining() {
  # Convert a unix-epoch reset time into "h:mm" remaining.
  local resets_at=$1
  [ -z "$resets_at" ] && return
  local now secs hrs mins
  now=$(date +%s)
  secs=$((resets_at - now))
  [ "$secs" -le 0 ] && echo "0:00" && return
  hrs=$((secs / 3600))
  mins=$(( (secs % 3600) / 60 ))
  printf '%d:%02d' "$hrs" "$mins"
}

short_path() {
  # Replace $HOME with ~ and ellipsise from the left if too long.
  local p="${1/#$HOME/~}"
  local max=${2:-38}
  if [ ${#p} -gt "$max" ]; then
    echo "…${p: -$((max-1))}"
  else
    echo "$p"
  fi
}

usage_bar() {
  # Render a coloured progress bar for percentage $1 of width $2.
  local pct=$1 width=$2 color
  if   [ "$pct" -ge 90 ]; then color="$RED"
  elif [ "$pct" -ge 70 ]; then color="$YELLOW"
  else                         color="$GREEN"
  fi
  local filled=$((pct * width / 100))
  [ "$filled" -gt "$width" ] && filled=$width
  local empty=$((width - filled))
  printf -v f "%${filled}s"; printf -v e "%${empty}s"
  echo -ne "${color}${f// /█}${e// /░}${RESET} ${pct}%"
}

# --- Derived workspace info --------------------------------------------------
MINS=$((DURATION_MS / 60000))
SECS=$(((DURATION_MS % 60000) / 1000))
COST_FMT=$(printf '$%.2f' "$COST")

PROJECT_NAME="${DIR##*/}"
BRANCH=""
BRANCH_NAME=""
WT=""
if git -C "$DIR" rev-parse --git-dir > /dev/null 2>&1; then
  BRANCH_NAME=$(git -C "$DIR" branch --show-current 2>/dev/null)
  BRANCH=" | ${BRANCH_NAME}"
  GIT_DIR_ABS=$(cd "$DIR" && cd "$(git rev-parse --git-dir)" && pwd)
  GIT_COMMON_ABS=$(cd "$DIR" && cd "$(git rev-parse --git-common-dir)" && pwd)
  if [ "$GIT_DIR_ABS" != "$GIT_COMMON_ABS" ]; then
    # Inside a worktree: report the main repo's name and tag the line.
    MAIN_REPO="${GIT_COMMON_ABS%/.git}"
    PROJECT_NAME="${MAIN_REPO##*/}"
    WT=" ${DIM}(wt)${RESET}"
  fi
fi

# --- Tasks (optional, pluggable) --------------------------------------------
ALL_TASKS=""
if [ -n "${MUXCLAUDE_TASKS_CMD:-}" ] && [ -x "${MUXCLAUDE_TASKS_CMD%% *}" ]; then
  # shellcheck disable=SC2086
  ALL_TASKS=$($MUXCLAUDE_TASKS_CMD "$PROJECT_NAME" "$DIR" 2>/dev/null)
fi

format_tasks() {
  [ -z "$ALL_TASKS" ] && return
  while IFS=$'\t' read -r status title; do
    case "$status" in
      completed)   echo -e "${DIM}✓ ${title}${RESET}" ;;
      in_progress) echo -e "${GREEN}→ ${title}${RESET}" ;;
      pending)     echo -e "  ${title}" ;;
      blocked)     echo -e "${RED}✗ ${title}${RESET}" ;;
    esac
  done <<< "$ALL_TASKS"
}

# --- CI checks (cached; fetched in background by ci-fetch.sh) ---------------
# Refresh policy:
#   * Cache missing             → fetch immediately
#   * Local commit moved        → fetch (CI is now reporting on a different sha)
#   * Same commit + any pending → fetch every 60s
#   * No PR for branch          → poll every 300s (a PR may be opened externally)
#   * PR fresh (<10 min) + zero checks → poll every 30s (workflows still registering)
#   * Same commit + all terminal → don't auto-fetch (F5 in the sidebar to force)
# A PostToolUse hook (hooks/pr-created-refresh-ci.sh) also kicks off an
# immediate fetch when Claude itself runs `gh pr create` successfully, so we
# don't have to wait on either the 300s or 30s windows post-creation.
CI_CACHE=""
CI_COMMIT_SHA=""
if [ -n "$BRANCH_NAME" ] && command -v gh >/dev/null 2>&1; then
  CI_REPO_ID=""
  CI_REPO_ID=$(git -C "$DIR" config --get remote.origin.url 2>/dev/null \
                 | sed -E 's#.*[:/]([^/:]+/[^/]+)(\.git)?$#\1#; s#\.git$##')
  CI_COMMIT_SHA=$(git -C "$DIR" rev-parse HEAD 2>/dev/null)
  if [ -n "$CI_REPO_ID" ]; then
    CI_KEY="${CI_REPO_ID//\//_}__${BRANCH_NAME//\//_}"
    CI_CACHE="$HOME/.claude/cache/ci/${CI_KEY}.json"
    NOW=$(date +%s)

    spawn_fetch=0
    if [ ! -r "$CI_CACHE" ]; then
      spawn_fetch=1
    else
      cached_sha=$(jq -r '.commit_sha // ""' "$CI_CACHE" 2>/dev/null)
      has_pr=$(jq -r '(.pr.number // empty) | tostring' "$CI_CACHE" 2>/dev/null)
      has_pending=$(jq -r 'try ([.checks[].bucket] | any(. == "pending")) catch false' "$CI_CACHE" 2>/dev/null)
      checks_count=$(jq -r '(.checks // []) | length' "$CI_CACHE" 2>/dev/null)
      pr_created_at=$(jq -r '.pr.createdAt // ""' "$CI_CACHE" 2>/dev/null)
      cache_age=$(( NOW - $(stat -f '%m' "$CI_CACHE" 2>/dev/null || echo "$NOW") ))

      # Time since the PR was opened, in seconds. macOS-only date parser.
      # Used to detect the "just-opened PR but workflows haven't registered"
      # window where checks_count==0 isn't actually terminal.
      pr_age=999999
      if [ -n "$pr_created_at" ]; then
        pr_age=$(( NOW - $(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pr_created_at" "+%s" 2>/dev/null || echo "$NOW") ))
      fi

      if [ -n "$CI_COMMIT_SHA" ] && [ "$cached_sha" != "$CI_COMMIT_SHA" ]; then
        spawn_fetch=1
      elif [ "$has_pending" = "true" ]; then
        [ "$cache_age" -ge 60 ] && spawn_fetch=1
      elif [ -z "$has_pr" ]; then
        # No PR known — keep occasional polling in case one gets opened.
        [ "$cache_age" -ge 300 ] && spawn_fetch=1
      elif [ -n "$has_pr" ] && [ "$checks_count" = "0" ] && [ "$pr_age" -lt 600 ]; then
        # Fresh PR (< 10 min old) but no workflows registered yet. GitHub is
        # still queuing the run; what looks like "all terminal" is actually
        # "checks haven't appeared on the PR yet". Poll at 30s so the sidebar
        # lights up within seconds of the first job appearing.
        [ "$cache_age" -ge 30 ] && spawn_fetch=1
      fi
      # else: same commit, all terminal — never auto-fetch (F5 to force).
    fi

    if [ "$spawn_fetch" -eq 1 ] && [ -x "$HOME/.claude/ci-fetch.sh" ]; then
      ( "$HOME/.claude/ci-fetch.sh" "$DIR" "$CI_CACHE" >/dev/null 2>&1 & ) >/dev/null 2>&1
    fi
  fi
fi

format_ci() {
  [ -z "$CI_CACHE" ] || [ ! -r "$CI_CACHE" ] && return
  local pr_num pr_title pass fail pending skip cancel summary width=${1:-40}
  pr_num=$(jq -r '.pr.number // ""' "$CI_CACHE" 2>/dev/null)
  [ -z "$pr_num" ] && return
  pr_title=$(jq -r '.pr.title // ""' "$CI_CACHE" 2>/dev/null)

  pass=$(jq    '[.checks[]|select(.bucket=="pass")]    |length' "$CI_CACHE")
  fail=$(jq    '[.checks[]|select(.bucket=="fail")]    |length' "$CI_CACHE")
  pending=$(jq '[.checks[]|select(.bucket=="pending")] |length' "$CI_CACHE")
  skip=$(jq    '[.checks[]|select(.bucket=="skipping")]|length' "$CI_CACHE")
  cancel=$(jq  '[.checks[]|select(.bucket=="cancel")]  |length' "$CI_CACHE")

  # Truncate title so it fits the sidebar.
  if [ "${#pr_title}" -gt "$width" ]; then
    pr_title="${pr_title:0:$((width-1))}…"
  fi

  echo -e "${DIM}#${pr_num}${RESET} ${pr_title}"

  summary=""
  [ "$pass"    -gt 0 ] && summary+="${GREEN}✓ ${pass}${RESET}  "
  [ "$fail"    -gt 0 ] && summary+="${RED}✗ ${fail}${RESET}  "
  [ "$pending" -gt 0 ] && summary+="${YELLOW}◔ ${pending}${RESET}  "
  [ "$cancel"  -gt 0 ] && summary+="${YELLOW}⊘ ${cancel}${RESET}  "
  [ "$skip"    -gt 0 ] && summary+="${DIM}⊝ ${skip}${RESET}"
  [ -n "$summary" ] && echo -e "$summary"

  # Surface the things you actually care about: failures and in-flight jobs.
  jq -r '.checks[]
           | select(.bucket=="fail" or .bucket=="pending")
           | "\(.bucket)\t\(.name)\t\(.workflow // "")"' "$CI_CACHE" 2>/dev/null \
    | head -6 \
    | while IFS=$'\t' read -r bucket name workflow; do
        case "$bucket" in
          fail)    icon="${RED}✗${RESET}" ;;
          pending) icon="${YELLOW}◔${RESET}" ;;
          *)       icon=" " ;;
        esac
        # Compose label, then truncate.
        if [ -n "$workflow" ] && [ "$workflow" != "$name" ]; then
          label="${name} (${workflow})"
        else
          label="${name}"
        fi
        if [ "${#label}" -gt $((width-2)) ]; then
          label="${label:0:$((width-3))}…"
        fi
        # Re-apply colour to the workflow part if we kept it.
        if [ -n "$workflow" ] && [ "$workflow" != "$name" ]; then
          short_label="${label%% (*}"
          wf_part="${label#"$short_label"}"
          echo -e "  ${icon} ${short_label}${DIM}${wf_part}${RESET}"
        else
          echo -e "  ${icon} ${label}"
        fi
      done
}

# =============================================================================
# TMUX mode: bottom line is minimal; rich info goes to a right-side sidebar pane
# =============================================================================
if [ -n "${TMUX:-}" ]; then
  echo -e "${CYAN}[$MODEL]${RESET} ${PROJECT_NAME}${WT}${BRANCH}"

  # Per-session sidebar file lives next to the transcript so multiple Claude
  # sessions (different windows) don't clobber each other.
  if [ -n "$TRANSCRIPT" ]; then
    SIDEBAR_FILE="${TRANSCRIPT%.jsonl}.sidebar.txt"
  else
    SIDEBAR_FILE="$HOME/.claude/sidebar.txt"
  fi
  LOOP_SCRIPT="$HOME/.claude/sidebar-loop.sh"

  # Responsive width: 1/4 of window, capped at 80, floor at 20.
  # Computed up front so content rendering (path truncation) can use it.
  WIN_W=$(tmux display -p '#{window_width}' 2>/dev/null)
  [ -z "$WIN_W" ] && WIN_W=120
  TARGET_W=$((WIN_W / 4))
  [ "$TARGET_W" -gt 80 ] && TARGET_W=80
  [ "$TARGET_W" -lt 20 ] && TARGET_W=20

  # Workspace section indents paths by 6 chars (label + spaces).
  PATH_W=$((TARGET_W - 6))
  [ "$PATH_W" -lt 16 ] && PATH_W=16

  # Build sidebar content atomically so the loop never reads a partial file.
  {
    echo -e "${BOLD}${MAGENTA}── Usage ──${RESET}"
    echo -e "${DIM}ctx${RESET}  $(usage_bar "$CTX_PCT" 12)"
    if [ -n "$FIVE_H_PCT" ]; then
      REM=$(fmt_remaining "$FIVE_H_RESETS")
      echo -e "${DIM}5h ${REM:-—}${RESET}"
      echo -e "     $(usage_bar "$FIVE_H_PCT" 12)"
    fi
    if [ -n "$SEVEN_D_PCT" ]; then
      REM=$(fmt_remaining "$SEVEN_D_RESETS")
      echo -e "${DIM}7d ${REM:-—}${RESET}"
      echo -e "     $(usage_bar "$SEVEN_D_PCT" 12)"
    fi
    echo
    echo -e "${BOLD}${YELLOW}── Session ──${RESET}"
    echo -e "${DIM}cost${RESET}  ${YELLOW}${COST_FMT}${RESET}"
    echo -e "${DIM}time${RESET}  ${MINS}m ${SECS}s"
    echo
    echo -e "${BOLD}${BLUE}── Workspace ──${RESET}"
    echo -e "${DIM}cwd${RESET}   $(short_path "$DIR" "$PATH_W")"
    if [ -n "$PROJECT_DIR" ] && [ "$PROJECT_DIR" != "$DIR" ]; then
      echo -e "${DIM}proj${RESET}  $(short_path "$PROJECT_DIR" "$PATH_W")"
    fi
    if [ -n "$BRANCH_NAME" ]; then
      echo -e "${DIM}br${RESET}    ${BRANCH_NAME}"
    fi
    if [ -n "$ADDED_DIRS" ]; then
      echo -e "${DIM}added:${RESET}"
      while IFS= read -r d; do
        [ -n "$d" ] && echo -e "  $(short_path "$d" "$((TARGET_W - 2))")"
      done <<< "$ADDED_DIRS"
    fi
    # Contextual key hints — accumulate as we render sections that have a
    # keystroke associated with them, then list at the bottom of the sidebar.
    KEYS_LINES=""

    CI_OUT=$(format_ci "$((TARGET_W - 2))")
    if [ -n "$CI_OUT" ]; then
      echo
      echo -e "${BOLD}${GREEN}── CI ──${RESET}"
      echo "$CI_OUT"
      KEYS_LINES+="<F5> Refresh CI"$'\n'
      KEYS_LINES+="<F6> Open PR"$'\n'
    fi
    if [ -n "$ALL_TASKS" ]; then
      echo
      echo -e "${BOLD}${CYAN}── Tasks ──${RESET}"
      format_tasks
    fi
    if [ -n "$KEYS_LINES" ]; then
      echo
      echo -e "${BOLD}${DIM}── Keys ──${RESET}"
      # `column -c TARGET_W` packs entries side-by-side when the sidebar is
      # wide enough, falls back to stacking them when it isn't. ANSI colour
      # is applied to the whole block so column doesn't mis-count widths.
      echo -ne "${DIM}"
      printf '%s' "$KEYS_LINES" | column -c "$TARGET_W"
      echo -ne "${RESET}"
    fi
  } > "${SIDEBAR_FILE}.tmp" && mv "${SIDEBAR_FILE}.tmp" "$SIDEBAR_FILE"

  # Loop script must exist; it's installed alongside statusline.sh.
  if [ ! -x "$LOOP_SCRIPT" ]; then
    exit 0
  fi

  # Find existing sidebar pane in current window, or create one.
  WIN_ID=$(tmux display -p '#{window_id}' 2>/dev/null)
  SIDEBAR_PANE=$(tmux list-panes -t "$WIN_ID" -F '#{pane_id} #{@claude_sidebar}' 2>/dev/null \
                   | awk '$2=="1"{print $1; exit}')

  # Advertise the current session's sidebar file on a window-scoped tmux
  # option. The loop script reads this each tick so whichever Claude session
  # most recently ran statusline owns the sidebar.
  tmux set-option -w -t "$WIN_ID" @claude_sidebar_file "$SIDEBAR_FILE" 2>/dev/null

  # Publish CI context for the F5/F6 popup helpers and the conditional
  # tmux key bindings (see tmux/muxclaude.tmux.conf). Setting these makes
  # the bindings active in this window; clearing them passes the keys
  # through to whatever app is running.
  if [ -n "$CI_CACHE" ]; then
    tmux set-option -w -t "$WIN_ID" @claude_ci_dir   "$DIR"      2>/dev/null
    tmux set-option -w -t "$WIN_ID" @claude_ci_cache "$CI_CACHE" 2>/dev/null
  fi

  if [ -z "$SIDEBAR_PANE" ]; then
    # Respawn guard: the SessionEnd hook stamps an epoch into
    # @claude_sidebar_disabled_at right before killing the pane. If a
    # statusline tick fires inside that teardown window we'd otherwise spawn
    # a fresh sidebar with nothing left to clean it up. Honour the marker for
    # ~10s, then treat it as stale (so a new claude session in the same tmux
    # window isn't permanently locked out).
    DISABLED_AT=$(tmux show-options -wqv -t "$WIN_ID" @claude_sidebar_disabled_at 2>/dev/null)
    if [ -n "$DISABLED_AT" ]; then
      NOW=$(date +%s)
      if [ $((NOW - DISABLED_AT)) -lt 10 ]; then
        exit 0
      fi
      tmux set-option -wu -t "$WIN_ID" @claude_sidebar_disabled_at 2>/dev/null
    fi

    SIDEBAR_PANE=$(tmux split-window -h -d -l "$TARGET_W" -t "${TMUX_PANE:-$WIN_ID}" \
                    -P -F '#{pane_id}' "$LOOP_SCRIPT" 2>/dev/null)
    [ -n "$SIDEBAR_PANE" ] && tmux set -pt "$SIDEBAR_PANE" @claude_sidebar 1 2>/dev/null
  else
    CUR_W=$(tmux display -p -t "$SIDEBAR_PANE" '#{pane_width}' 2>/dev/null)
    if [ -n "$CUR_W" ] && [ "$CUR_W" != "$TARGET_W" ]; then
      tmux resize-pane -t "$SIDEBAR_PANE" -x "$TARGET_W" 2>/dev/null
    fi
  fi

  exit 0
fi

# =============================================================================
# Non-TMUX mode: two-line statusline + columnised tasks underneath
# =============================================================================
echo -e "${CYAN}[$MODEL]${RESET} ${PROJECT_NAME}${WT}${BRANCH}"
LINE2="ctx $(usage_bar "$CTX_PCT" 10)"
if [ -n "$FIVE_H_PCT" ]; then
  FIVE_H_REM=$(fmt_remaining "$FIVE_H_RESETS")
  FIVE_H_LABEL="${FIVE_H_REM:-5h}"
  LINE2="${LINE2} ${DIM}|${RESET} ${FIVE_H_LABEL} $(usage_bar "$FIVE_H_PCT" 5)"
fi
if [ -n "$SEVEN_D_PCT" ]; then
  SEVEN_D_REM=$(fmt_remaining "$SEVEN_D_RESETS")
  SEVEN_D_LABEL="${SEVEN_D_REM:-7d}"
  LINE2="${LINE2} ${DIM}|${RESET} ${SEVEN_D_LABEL} $(usage_bar "$SEVEN_D_PCT" 5)"
fi
LINE2="${LINE2} ${DIM}|${RESET} ${YELLOW}${COST_FMT}${RESET} ${DIM}|${RESET} ${MINS}m ${SECS}s"
echo -e "$LINE2"

if [ -z "$ALL_TASKS" ]; then
  exit 0
fi

FORMATTED=""
while IFS=$'\t' read -r status title; do
  case "$status" in
    completed)   line="✓ ${title}" ;;
    in_progress) line="→ ${title}" ;;
    pending)     line="  ${title}" ;;
    blocked)     line="✗ ${title}" ;;
  esac
  [ -n "$FORMATTED" ] && FORMATTED="${FORMATTED}"$'\n'"${line}" || FORMATTED="$line"
done <<< "$ALL_TASKS"

COLS=160
echo "$FORMATTED" | pr -a -t -3 -w "$COLS" | head -4
