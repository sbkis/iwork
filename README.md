# iwork

A small Bash CLI for **task-oriented git worktrees** across multiple repositories,
with optional [tmux](https://github.com/tmux/tmux) and [Claude Code](https://claude.com/claude-code) / Codex integration.

Your tmux is usually organized per-repo, but agent work is task-shaped: one branch
spanning several repositories. `iwork` groups the worktrees for a task into a single
folder, maps that folder to one tmux window, and seeds it with context files so an
agent knows the scope.

## Layout it manages

`iwork` assumes your project repositories live as direct children of a single
directory (`IWORK_REPO_DIR`). Task folders are collected in a tasks directory
(`IWORK_TASKS_DIR`, default `$IWORK_REPO_DIR/tasks`):

```
~/dev/projects/                  # IWORK_REPO_DIR (you choose this)
├── backend-api/                 # your repos (real git repos, direct children)
├── frontend/
└── tasks/                       # IWORK_TASKS_DIR — task folders live here
    └── feat-login/              # one task folder
        ├── backend-api/         # a git worktree, named after its repo
        ├── frontend/            # another worktree, same branch
        ├── CLAUDE.md            # generated task context (scopes the agent)
        └── AGENTS.md            # identical content, for Codex
```

Each worktree subdirectory carries the same name as the repo it came from, so a
path inside a task reads like a path inside the repo itself.

Older versions named these `repo--branch-slug`. Existing folders keep working —
`iwork rm -r <repo>` still finds them — and you can rename them by hand if you
want the layouts consistent:

```bash
git -C ~/dev/projects/backend-api worktree move \
  ~/dev/projects/tasks/feat-login/backend-api--feat-login \
  ~/dev/projects/tasks/feat-login/backend-api
```

The tool itself can live anywhere — it does **not** need to be under `IWORK_REPO_DIR`.

## Requirements

- `bash` and `git` (any version with `git worktree` — i.e. anything modern)
- `tmux` — optional; only needed for the window management. Everything works
  without it (see `--no-tmux`).
- `python3` — only needed for `iwork install-hooks`.
- `claude` / `codex` on your `PATH` — only for those subcommands.

## Setup

### 1. Clone

```bash
git clone https://github.com/sbkis/iwork.git
```

Clone it wherever you like.

### 2. Put `iwork` on your PATH

Symlink the script into a directory already on your `PATH`:

```bash
ln -s /path/to/iwork/iwork ~/.local/bin/iwork
```

If `~/.local/bin` is not on your `PATH`, add `export PATH="$HOME/.local/bin:$PATH"`
to your shell rc.

### 3. Configure

```bash
iwork init
```

This asks for your repo directory (and optionally a tasks directory) and writes
`~/.config/iwork/config`. The file is plain shell, so you can also create or edit
it by hand:

```sh
IWORK_REPO_DIR="$HOME/dev/projects"
# IWORK_TASKS_DIR="$IWORK_REPO_DIR/tasks"
```

### 4. Enable shell integration (recommended)

`iwork cd` needs to change your shell's directory, and `park`/`claude`/`codex` are
nicer when the shell can `cd` for you — so `iwork` ships a wrapper function plus tab
completion. Source it from your shell rc.

**zsh** (`~/.zshrc`) — make sure completion is initialized first:

```zsh
autoload -Uz compinit && compinit
command -v iwork >/dev/null && source <(iwork --completion zsh)
```

**bash** (`~/.bashrc`):

```bash
command -v iwork >/dev/null && source <(iwork --completion bash)
```

Open a new shell (or `source` your rc) to pick it up. Without this step the tool
still works, except `iwork cd` — which requires the wrapper — will tell you to set
it up.

### 5. Install Claude Code status hooks (optional)

These keep the tmux window name in sync with the agent state
(`*task` = busy, `!task` = waiting for you). Idempotent; shows the change and asks
before writing.

```bash
iwork install-hooks              # edits ~/.claude/settings.json
iwork install-hooks path/to/settings.json   # or a specific settings file
```

### 6. Recommended tmux config (optional)

Task windows live in a dedicated `tasks` session. These `~/.tmux.conf` additions make
it easy to move between your regular sessions and the tasks session, and surface how
many agents are waiting:

```tmux
setw -g automatic-rename off        # let iwork own the task window names

bind Tab switch-client -l           # prefix+Tab: toggle last session
bind T switch-client -t tasks       # prefix+T: jump to tasks session

# Waiting-agent counter in the status bar. -a covers every session, so it also
# counts agents inside per-task `tasks-*` sessions (see Big tasks below).
set -g status-right '!#(tmux list-windows -a -F "#W" 2>/dev/null | grep -c "^!")  %Y-%m-%d %H:%M:%S'
```

Only `iwork` marks window names with `!`, so counting across all sessions is safe.
With `--big` in play, `prefix + s` lists the `tasks-` sessions together.

## Quick start

```bash
# Create a task: worktrees for two repos on a new branch, in one folder
iwork feat/login-bug -r backend-api frontend

# Add another repo to that task later
iwork add-repo feat-login-bug -r shared-lib

# Remove one repo's worktree, or the whole task
iwork rm feat-login-bug -r shared-lib
iwork rm feat-login-bug

# Jump back into the task (tmux window if present, else cd)
iwork cd feat-login-bug

# Run an agent in the task window
iwork claude feat-login-bug
iwork codex feat-login-bug

# Move the branch you're currently on into a task folder (stashes/restores WIP)
iwork park task-billing-followup

# See your tasks (with live agent status inside tmux)
iwork list
```

## Detached mode

`--detach` spins a task up without dragging you to it. The window is still
created and the agent still starts in it — your client just stays where it is:

```bash
iwork --detach feat/login-bug -r backend-api frontend   # create, stay put
iwork --detach claude feat-login-bug                    # start an agent, stay put
iwork --detach park task-billing-followup               # park, stay put
```

Useful when you want an agent chewing on something while you keep working, and
for scripting: because nothing needs a client to switch, `--detach` also works
from **outside** tmux, creating the tasks session in the background.

Pick the task up whenever you like with `iwork cd <task>`, or watch it from
`iwork list` — the `*` / `!` markers report whether the agent is busy or waiting
for you. Set `IWORK_DETACH=1` in your config to make this the default.

## Big tasks: a session per task

One window is thin for a task spanning four repos. `--big` gives the task a whole
tmux session instead, named `<tmux-session>-<task>` — `tasks-feat-x` by default,
so all of them sort and grep together:

```bash
iwork --big feat/big-thing -r backend-api frontend shared-lib admin
```

```
session tasks-feat-big-thing
├── window "feat-big-thing"   claude | shell          — at the task root
├── window "admin"            nvim . | shell          — inside tasks/…/admin
├── window "backend-api"      nvim . | shell
├── window "frontend"         nvim . | shell
└── window "shared-lib"       nvim . | shell
```

The editor is `IWORK_EDITOR` (default `nvim`), run as a command line with the
worktree appended — so `IWORK_EDITOR="code -n"` or `IWORK_EDITOR=hx` both work.
You land on the agent window; the repo windows are built behind it.

How it fits with everything else:

- **The agent window keeps the task name**, so the Claude Code status hooks still
  rename it `*task` / `!task`, and `iwork list` reports it — tagged `(session)` so
  you can see which tasks own one.
- **`cd`, `claude`, `codex`** find a task in its own session or in the shared one,
  whether or not you pass `--big` again.
- **`add-repo`** adds a window for the new repo to a live session.
- **`rm`** kills the whole session, and says so before it does — anything unsaved
  in those editors goes with it.
- **`--big --detach`** builds the session without moving you into it, and works
  from outside tmux entirely.

If a task is already open as a plain window in the shared session, `--big` will
not start a second agent for it in a new session; close that window first.

Set `IWORK_BIG=1` in your config to make every task work this way.


## Cleaning up

```bash
iwork rm feat-login-bug                  # every worktree, plus the task folder
iwork rm feat-login-bug -r shared-lib    # just that repo's worktree
iwork rm -f feat-login-bug               # don't ask, and drop uncommitted work
```

`rm` removes git worktrees (via `git worktree remove`, then a prune in the parent
repo) and, when no `-r` is given, the generated `CLAUDE.md`/`AGENTS.md`, the task
folder, and its tmux window. It shows what it is about to do and asks for
confirmation first.

Things it will not do:

- **Delete branches.** The branch survives every removal; only the working copy
  goes away.
- **Throw away uncommitted work.** If any target worktree is dirty, `rm` names it
  and stops. Pass `-f` to remove it anyway (which also skips the prompt).
- **Delete files it didn't create.** If anything besides the worktrees and the
  generated context files is left in the task folder, the folder is kept.

Removing the task you are currently in is fine — with the shell integration
sourced, your shell is moved up to the tasks directory afterwards. If the tmux
window being removed is the one you are sitting in, `iwork` leaves it to you to
close.

Run `iwork -h` for the full command reference.

## Configuration

Configuration is read from `~/.config/iwork/config` (respects `$XDG_CONFIG_HOME`;
override the file location with `IWORK_CONFIG_FILE`). The file is plain shell,
sourced by `iwork`. Every setting can also be set as an environment variable, and
**environment variables override the config file** — handy for per-invocation
overrides.

| Variable | Default | Purpose |
|---|---|---|
| `IWORK_REPO_DIR` | — (required) | Directory whose direct children are your git repos |
| `IWORK_TASKS_DIR` | `$IWORK_REPO_DIR/tasks` | Where task folders are created |
| `IWORK_TMUX_SESSION` | `tasks` | tmux session that holds task windows |
| `IWORK_CONTEXT_TEMPLATE` | `~/.config/iwork/task-context.md.tmpl` | Template for the generated `CLAUDE.md`/`AGENTS.md` (seeded with a default on first use, then yours to edit) |
| `IWORK_EDITOR` | `nvim` | Editor started in each repo window under `--big`; run as a command line with the worktree appended |
| `IWORK_NO_TMUX` | unset | Set to skip all tmux handling (same as the `--no-tmux` flag) |
| `IWORK_NO_CONTEXT` | unset | Set to skip writing task context files (same as `--no-context`) |
| `IWORK_DETACH` | unset | Set to never switch to the task window (same as `--detach`) |
| `IWORK_BIG` | unset | Set to give every task its own session (same as `--big`) |
| `IWORK_ASSUME_YES` | unset | Set to `1` to skip confirmation prompts (`install-hooks`, `rm`) |

Leading flags `--no-tmux`, `--no-context`, `--detach` and `--big` apply
per-invocation, e.g. `iwork --no-tmux claude feat-login-bug`.

## Updating

```bash
git -C /path/to/iwork pull
```

The symlink points at the script in the repo, so a pull is all that's needed. If the
completion output changed, open a new shell (or re-`source` your rc) to reload the
wrapper.
