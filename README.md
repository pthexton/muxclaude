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
- **Optional Stop hook** that keeps Claude moving while your tracker has
  outstanding work, and lets it stop cleanly otherwise.
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
   register the `SessionEnd` and `PostToolUse` hooks (plus the optional
   `Stop` hook). Existing config is preserved; previous muxclaude entries
   are deduplicated.
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

`statusline.sh` runs on every Claude status refresh with a JSON payload on
stdin. The full field reference lives in the `JSON INPUT FIELDS` comment
block at the top of the script.

To capture a live sample for inspection, add this to your `~/.zshrc` (or
`~/.bashrc`) and start a new terminal — see [Setting environment
variables](#setting-environment-variables) below for why this matters:

```sh
export MUXCLAUDE_DEBUG_INPUT=$HOME/.claude/last-statusline-input.json
```

The next status refresh dumps the full JSON to that path.

### Setting environment variables

Every option muxclaude exposes as an environment variable
(`MUXCLAUDE_TASKS_CMD`, `MUXCLAUDE_DEBUG_INPUT`) has to be present in the
shell that launches `claude`. Some things to know:

- Set them in your shell rc (`~/.zshrc`, `~/.bashrc`, …) so every new
  terminal inherits them, then start a fresh terminal for the change to
  take effect.
- Running `export FOO=bar` in a *different* tab or window has **no
  effect** on a `claude` session that is already running. Each running
  `claude` keeps the environment of the shell that launched it.
- The easiest way to get `MUXCLAUDE_TASKS_CMD` set up correctly is to let
  the installer write the export for you:
  `./install.sh --tasks-cmd /path/to/your/tasks-script`.

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

Uncomment the one that fits, or roll your own.

`MUXCLAUDE_TASKS_CMD` has to be exported in the shell that launches
`claude` — see [Setting environment variables](#setting-environment-variables).
The simplest way is to let the installer write the export to your `~/.zshrc`
for you:

```sh
./install.sh --tasks-cmd ~/.claude/muxclaude-tasks.sh
```

If you don't want a tasks section at all, leave `MUXCLAUDE_TASKS_CMD`
unset — the section will simply be hidden.

### Optional: a Stop hook that keeps Claude moving

The hook reuses `MUXCLAUDE_TASKS_CMD`. When Claude tries to end its turn,
it checks the tracker: if anything is `pending` or `in_progress`, it emits
a `block` decision and Claude keeps going; otherwise the Stop succeeds
cleanly with no extra round-trip.

Enable with:

```sh
./install.sh --with-stop-hook
```

Off by default — the only reason to install it is the auto-continue
behaviour.

## CI section + F5 / F6 popups

When the current branch has a PR open on GitHub, the sidebar gains a CI
section: PR number/title, a coloured pass/fail/pending count, and the names
of any failing or in-flight jobs. Cached under `~/.claude/cache/ci/` and
refreshed in the background.

| Key | Action                                                         |
|-----|----------------------------------------------------------------|
| F5  | Force a fresh CI fetch — popup shows progress + result summary |
| F6  | Open the current branch's PR — popup confirms, or surfaces every failure path (no PR, gh error, …) |

Both bindings are gated to Claude windows; outside one, the keys pass
through to whatever app is running. Enable by adding to `~/.tmux.conf`:

```sh
source-file ~/.claude/tmux/muxclaude.tmux.conf
```

## Hooks installed

| Trigger     | Hook                          | Default                   |
|-------------|-------------------------------|---------------------------|
| SessionEnd  | `tmux-cleanup-sidebar.sh`     | always                    |
| PostToolUse | `pr-created-refresh-ci.sh`    | always                    |
| Stop        | `stop-continue-tasks.sh`      | only with `--with-stop-hook` |

## Advanced: deterministic vetoes via PreToolUse hooks

Anything you can detect by inspecting the tool call payload, you can
*deterministically block* with a `PreToolUse` hook that returns
`permissionDecision: "ask"`. Unlike instructions in CLAUDE.md or a system
prompt, this is enforced by the harness — Claude can't choose to ignore it.

A worked example lives at `examples/hooks/pr-create-multi-ticket-check.js`:
it watches for `gh pr create` invocations whose title or body mention more
than one Jira-style ticket key (because GitHub→Jira automations often
auto-close every key they see in a merged PR body — silently retiring
tickets you only meant to *reference*). Edit the project prefix at the top
of the file and wire it into `settings.json` under `hooks.PreToolUse` with
`matcher: "Bash"`.

The script is JavaScript rather than shell because Claude Code already
ships with Node.js, so there's no extra runtime to install. The example
isn't auto-installed — copy it into `~/.claude/hooks/`, customise, and
register it yourself.

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
