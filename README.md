# muxclaude

A Claude Code statusline + tmux sidebar combo. When you're inside tmux, you
get a live right-hand pane showing usage bars, session cost, workspace info
and (optionally) your task list. When you're not in tmux, you get a compact
two-line status with the same data.

```
┌──────────────────────────────────────────┬─────────────────────┐
│ claude code session                      │ ── Usage ──         │
│                                          │ ctx  ███░░░░░ 35%   │
│ > Tell me about the codebase             │ 5h 2:14             │
│                                          │      █░░░░░░░ 12%   │
│ ...                                      │ 7d 6d:03            │
│                                          │      ░░░░░░░░  4%   │
│                                          │                     │
│                                          │ ── Session ──       │
│                                          │ cost  $0.42         │
│                                          │ time  2m 5s         │
│                                          │                     │
│                                          │ ── Workspace ──     │
│                                          │ cwd   ~/dev/foo     │
│                                          │ br    main          │
│                                          │                     │
│                                          │ ── Tasks ──         │
│                                          │ → Wire up sidebar   │
│ [Sonnet 4.6] foo | main                  │ ✓ Initial scaffold  │
└──────────────────────────────────────────┴─────────────────────┘
```

## Features

- **Statusline that adapts to tmux** — minimal one-liner inside tmux (so the
  rich data goes in the sidebar instead), full two-line status with bars
  outside tmux.
- **Auto-spawning sidebar pane** with usage bars (context, 5h limit, 7d
  limit), session cost/time, workspace paths, branch, worktree indicator.
- **Pluggable task source** — point `MUXCLAUDE_TASKS_CMD` at any script that
  emits `status\ttitle` lines and your kanban/todo shows up in the sidebar.
- **CI section + F5/F6 tmux popups** — when the current branch has a PR,
  the sidebar shows pass/fail/pending counts, F5 force-refreshes the cache
  with visible progress feedback, F6 opens the PR in your browser. Both
  surface success and failure paths in tmux popups so the result is
  unmissable. Hidden when there's nothing to show.
- **`claude` shell function** that auto-starts a tmux session if you're not
  already in one — sidebar appears from the very first render.
- **Per-session sidebar files** keyed off the transcript path, so multiple
  Claude windows don't clobber each other's sidebars.
- **SessionEnd hook** that cleans up the sidebar pane when Claude exits.
- **PostToolUse hook** that triggers an instant CI refresh whenever Claude
  itself runs `gh pr create`, so the sidebar lights up within seconds of a
  fresh PR rather than waiting on the polling cadence.
- **Optional Stop hook** that nudges Claude to check your task tracker before
  ending its turn.
- **Idempotent installer** that backs up anything it replaces.

## Requirements

- macOS or Linux
- `bash`, `jq`, `tmux`, `git`, `awk` (BSD or GNU)
- zsh for the `claude()` wrapper (the rest is bash)
- `gh` (GitHub CLI) — *optional*; required only for the CI section and the
  F5/F6 popups. Without it, those features stay hidden and everything else
  works.

## Install

```sh
git clone <this repo> ~/Developer/gh/muxclaude
cd ~/Developer/gh/muxclaude
./install.sh
source ~/.zshrc
claude
```

The installer:

1. Copies `statusline.sh`, `sidebar-loop.sh`, hooks, and the example tasks
   provider into `~/.claude/`.
2. Patches `~/.claude/settings.json` to point `statusLine` at the script and
   register the `SessionEnd` (and optional `Stop`) hooks. Existing config is
   preserved; previous muxclaude entries are deduplicated.
3. Adds a small block to `~/.zshrc` that sources the tmux-aware `claude()`
   function. The block is wrapped in `# >>> muxclaude >>>` markers so re-runs
   replace it cleanly.

A timestamped backup is made of every file the installer modifies.

### Installer flags

| Flag                 | Effect                                                     |
| -------------------- | ---------------------------------------------------------- |
| `--prefix DIR`       | Install into `DIR` instead of `~/.claude`                  |
| `--with-stop-hook`   | Also install the optional Stop hook (see *Tasks* below)    |
| `--no-zshrc`         | Don't touch `~/.zshrc`                                     |
| `--tasks-cmd PATH`   | Set `MUXCLAUDE_TASKS_CMD=PATH` in the .zshrc snippet       |
| `--dry-run`          | Show what would change; don't write anything               |

## Customising the statusline

`statusline.sh` is invoked by Claude Code on every status refresh, with a
JSON document on stdin. The full set of fields available to you is documented
at the top of the script — search for `JSON INPUT FIELDS`. Highlights:

| jq path                                 | What it is                              |
| --------------------------------------- | --------------------------------------- |
| `.model.display_name` / `.model.id`     | The active model                        |
| `.workspace.current_dir`                | Active working directory                |
| `.workspace.project_dir`                | Where Claude was started                |
| `.workspace.added_dirs[]`               | Extra `/add-dir` roots                  |
| `.cost.total_cost_usd`                  | Running session cost                    |
| `.cost.total_duration_ms`               | Wall time                               |
| `.cost.total_lines_added` / `_removed`  | Diff lines applied this session         |
| `.context_window.used_percentage`       | Context fill (0–100)                    |
| `.rate_limits.five_hour.used_percentage`| 5-hour usage cap                        |
| `.rate_limits.seven_day.used_percentage`| 7-day usage cap                         |
| `.rate_limits.*.resets_at`              | Unix epoch when the cap resets          |
| `.transcript_path`                      | JSONL file for this session             |
| `.session_id`                           | Stable id for this session              |

To explore live data:

```sh
export MUXCLAUDE_DEBUG_INPUT=$HOME/.claude/last-statusline-input.json
```

The next status refresh will dump the full JSON object to that path.

## Plugging in your task tracker

The sidebar's "Tasks" section is fed by an external command of your choice.
Set `MUXCLAUDE_TASKS_CMD` to its absolute path — `statusline.sh` will run
`$MUXCLAUDE_TASKS_CMD <project> <working_dir>` and treat each line of stdout
as:

```
<status>\t<title>
```

`<status>` must be one of `pending`, `in_progress`, `completed`, `blocked`.

A starter script is dropped at `~/.claude/muxclaude-tasks.sh` during install.
It contains commented-out adapters for:

- A static demo (verify the pipeline before wiring real data)
- A plain `.tasks/TODO.md` file with `[ ]`, `[x]`, `[>]`, `[!]` markers
- GitHub issues assigned to you (`gh issue list ...`)
- Any custom CLI that produces structured output

Uncomment the one that fits, or roll your own. As long as the output format
is right, the sidebar will pick it up on the next status refresh.

If you don't want a tasks section at all, leave `MUXCLAUDE_TASKS_CMD` unset
— the section will simply be hidden.

### Optional: a Stop hook that keeps Claude moving

Once you've wired up a task source, it's natural to also have Claude
*automatically continue* if there's still pending work in your tracker
when it tries to end a turn. Claude Code supports this via a `Stop` hook
that returns a `block` decision with a reason — Claude reads the reason
and decides whether to keep going.

A template ships at `~/.claude/hooks/stop-continue-tasks.sh`. To enable it:

1. Edit the `REASON=…` line near the bottom to mention *your* tracker by
   name. The more specific you are about what to look at, the better the
   model's decision will be:

   ```sh
   # Examples
   REASON="check Linear for any open tickets assigned to me on this branch and continue"
   REASON="look at .tasks/TODO.md — if anything is pending or in_progress, keep going"
   REASON="check the swift-todo-manager mcp for tasks to perform next and continue"
   ```

2. Re-run the installer with `--with-stop-hook`, or add the entry to
   `settings.json` by hand:

   ```jsonc
   "Stop": [
     {
       "hooks": [
         {
           "type": "command",
           "command": "/Users/you/.claude/hooks/stop-continue-tasks.sh",
           "timeout": 10,
           "statusMessage": "Checking for remaining task work"
         }
       ]
     }
   ]
   ```

The hook short-circuits on the second stop in the same turn (it inspects
`stop_hook_active`), so Claude can always actually finish — it just gets
one nudge per turn.

Without a task source this hook adds latency for no benefit, which is why
it's **off by default**.

## CI section + F5 / F6 popups

When the current branch has a PR open on GitHub, the sidebar gains a CI
section showing the PR number/title and a coloured count of pass/fail/pending
checks, plus the names of any failing or in-flight jobs. The data is cached
under `~/.claude/cache/ci/` and refreshed in the background by
`statusline.sh` on a sliding cadence (60s while pending, 300s while no PR
exists, never while a terminal state is settled at the current commit).

Two tmux key bindings give you an escape hatch from the cache logic and
visible feedback for both:

| Key | Action                                  | Popup shows                               |
|-----|-----------------------------------------|-------------------------------------------|
| F5  | Force a fresh CI fetch                  | `⟳ Refreshing → ✓ Done. PR #N — pass/fail/pending` (or ✗ on failure) |
| F6  | Open the current branch's PR in browser | `→ Opening PR for branch X` (or ✗ no PR / git error / gh error) |

Both bindings are gated to Claude windows: outside a Claude window, F5 and
F6 fall through to whatever app is running. To enable them, source the
provided snippet from your tmux config:

```sh
# in ~/.tmux.conf
source-file ~/.claude/tmux/muxclaude.tmux.conf
```

Then `tmux source-file ~/.tmux.conf` to reload.

The popups are tiny (`tmux display-popup -h 7 -w 78`) and auto-close after a
few seconds — they're there to answer "did anything happen?" without
hijacking your screen.

## Hooks

`install.sh` always wires up:

- **SessionEnd → `tmux-cleanup-sidebar.sh`**: kills any pane in Claude's
  tmux window tagged with `@claude_sidebar=1`. Other windows' sidebars
  survive.
- **PostToolUse → `pr-created-refresh-ci.sh`**: when Claude runs a
  successful `gh pr create`, kicks off an immediate CI fetch so the sidebar
  doesn't sit on a stale "no PR" cache. The hook script self-filters on
  `tool_name == "Bash"` and the `gh pr create` substring, so it's a no-op
  for every other tool call.

Optional (off by default; enable with `--with-stop-hook`):

- **Stop → `stop-continue-tasks.sh`**: nudges Claude to check your task
  tracker before ending its turn. See the section above for setup.

## How the sidebar plumbing works

For the curious:

1. Each tick, `statusline.sh` writes a fully-rendered sidebar text to
   `<transcript>.sidebar.txt` (atomic via `mv`).
2. It records that path on the current tmux **window option**
   `@claude_sidebar_file`. Window-scoped, not session-scoped, so multiple
   Claude windows in one tmux session each get their own sidebar.
3. If no pane in the window is tagged `@claude_sidebar=1`, it splits one
   off (right-hand, sized to ~1/4 of the window) and runs `sidebar-loop.sh`
   in it. The new pane gets the tag.
4. `sidebar-loop.sh` polls `@claude_sidebar_file` every second, and only
   redraws when the file's mtime/size changes (or the pane was resized) —
   redrawing via cursor-home + erase-to-EOL rather than a full clear, so
   unchanged pixels don't flicker.

When Claude exits, the SessionEnd hook kills the tagged pane. To close a
respawn race (a statusline tick firing between the kill and Claude actually
exiting would otherwise spawn a fresh sidebar with nothing left to clean it
up), the hook also stamps `@claude_sidebar_disabled_at` on the window with
the current epoch. `statusline.sh` checks that marker before respawning and
skips for ~10s, after which the marker is treated as stale and cleared so a
new Claude session in the same tmux window isn't permanently locked out.

## Files

```
~/.claude/
├── statusline.sh                 ← entry point Claude Code calls each tick
├── sidebar-loop.sh               ← runs in the sidebar pane
├── ci-fetch.sh                   ← background PR + checks fetcher
├── refresh-ci.sh                 ← F5 popup: force a CI refresh
├── open-pr.sh                    ← F6 popup: open PR in browser
├── muxclaude-tasks.sh            ← (optional) your tasks adapter
├── settings.json                 ← hooks + statusLine config (patched)
├── cache/ci/<repo>__<branch>.json ← per-branch CI cache
├── shell/
│   └── claude-tmux.zsh           ← sourced from ~/.zshrc
├── tmux/
│   └── muxclaude.tmux.conf       ← F5/F6 bindings (source-file from tmux.conf)
└── hooks/
    ├── tmux-cleanup-sidebar.sh   ← SessionEnd
    ├── pr-created-refresh-ci.sh  ← PostToolUse (gh pr create)
    └── stop-continue-tasks.sh    ← Stop (optional)
```

## Uninstall

There's no dedicated uninstaller, but it's easy:

```sh
# Remove scripts
rm -f ~/.claude/{statusline.sh,sidebar-loop.sh,ci-fetch.sh,refresh-ci.sh,open-pr.sh,muxclaude-tasks.sh}
rm -rf ~/.claude/shell ~/.claude/tmux ~/.claude/cache/ci
rm -f ~/.claude/hooks/{tmux-cleanup-sidebar.sh,pr-created-refresh-ci.sh,stop-continue-tasks.sh}

# Restore settings.json from the most recent backup
ls -t ~/.claude/settings.json.bak.* | head -1 | xargs -I{} cp {} ~/.claude/settings.json

# Remove the source-file line from ~/.tmux.conf if you added one.
# Remove the # >>> muxclaude >>> ... # <<< muxclaude <<< block from ~/.zshrc.
```

## License

MIT (or your project's preferred license — adjust before publishing).
