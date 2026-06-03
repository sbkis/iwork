# iwork tmux task windows — design

Date: 2026-06-03
Status: approved pending review

## Problem

`iwork` creates task folders in `AAWORKTREES/<task>/` containing git worktrees of
multiple repos on one branch. The user's tmux is organized per-repo (one window per
repo in an `igloo` session), but agent work is task-shaped: a single claude session
in a task folder spans several repos. There is no visual mapping from tmux to tasks,
making it hard to track where agents are working and which ones need attention.

## Goal

Make tmux organization follow the task: one tmux window per task, named after the
task folder, with live agent status visible in the window name.

## Decisions

- **Granularity:** one tmux window per task, in the current session.
- **Trigger:** the window is created at task creation (`iwork <branch> -r ...`).
- **Layout:** two panes — left pane for the agent, right pane a plain shell, both
  in the task folder.
- **Agent:** claude auto-starts in the left pane on window creation.
- **Visibility:** Claude Code hooks update the window name with status markers.
- **Scope:** all task-entry commands (`claude`, `codex`, `cd`, `park`) become
  tmux-aware.
- **Implementation shape:** everything stays in the single `iwork` bash script;
  the status hook is `iwork --hook` wired into `~/.claude/settings.json`.

## 1. Task window creation (find-or-create)

New internal function `open_task_window <folder> [tool]`:

- Only acts when `$TMUX` is set; otherwise commands behave exactly as today.
- If a window named `<folder>` exists in the current session (matching with status
  markers stripped), `select-window` to it — never spawn a duplicate agent.
- Otherwise:
  - `tmux new-window -n <folder> -c <task-path>`
  - split horizontally, right pane also in `<task-path>`
  - `send-keys '<tool>' Enter` into the left pane. send-keys (rather than running
    the tool as the pane command) means the pane survives when the agent exits and
    keeps shell history.

Command behavior inside tmux:

| Command | Behavior |
|---|---|
| `iwork <branch> -r ...` | create worktrees, then open task window with claude started |
| `iwork claude/codex <task>` | find-or-create window (starting that tool if creating), switch to it |
| `iwork cd <task>` | switch to task window if one exists; plain cd in current pane otherwise |
| `iwork park <task>` | park as today, then open task window |

Outside tmux all commands keep today's behavior. A `--no-tmux` flag forces plain
behavior inside tmux.

## 2. Agent status in window names

Plain-text markers (the status bar is text-only):

- `feat-x` — idle / nothing running
- `*feat-x` — agent busy working
- `!feat-x` — agent waiting for the user (finished, or needs permission/input)

Driven by Claude Code hooks in `~/.claude/settings.json`:

| Hook event | Marker |
|---|---|
| `UserPromptSubmit` | `*` (busy) |
| `Stop` | `!` (done, waiting) |
| `Notification` (permission request / idle prompt) | `!` |

Each hook runs `iwork --hook`, which:

1. Reads the event JSON from stdin (`hook_event_name` field).
2. Exits silently unless `$TMUX_PANE` is set.
3. Looks up the current window name via `$TMUX_PANE`, strips any existing marker.
4. Verifies the base name is an existing AAWORKTREES folder — so ad-hoc claude runs
   in repo windows are never renamed.
5. Renames the window with the new marker.

A new `iwork install-hooks` subcommand adds these entries to
`~/.claude/settings.json` (idempotent; shows the change before writing).

`automatic-rename off` in the user's tmux config means tmux will not fight the
renames.

Codex has no equivalent hooks; codex windows keep the plain name. Acceptable
degradation.

## 3. `iwork list` upgrade

Inside tmux, `list` adds a status column for tasks that currently have a window:

```
feat-entitlements-structure    *running
feat-user-deletion-rework      !waiting
fix-product-sku-lookup
```

Outside tmux, output is unchanged.

## 4. Error handling

- All tmux operations are best-effort: if a tmux call fails, the underlying
  filesystem/git operation has already succeeded and its result is reported;
  the tmux failure is a warning, not a fatal error.
- `iwork --hook` never fails loudly — a broken hook must not disrupt the agent.
  It exits 0 on any unexpected condition.
- Window-name matching always strips markers first so a busy task (`*feat-x`)
  is still found by `iwork claude feat-x`.

## 5. Testing

Manual verification (the script has no test suite today):

- Create a task inside tmux: window appears, named correctly, claude starts left,
  shell right.
- Re-run `iwork claude <task>`: switches to the existing window, no duplicate.
- Run the same commands outside tmux: behavior identical to current version.
- Simulate hook events by piping JSON to `iwork --hook` inside a task window and
  observing the rename; confirm a repo-named window is left untouched.
- `--no-tmux` skips all window handling.

## Out of scope

- No cleanup/`done` command (possible follow-up).
- No multi-agent-per-task tracking; one window = one task.
- No changes to worktree-creation logic.
