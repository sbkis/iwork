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
        ├── backend-api--feat-login/   # a git worktree (named repo--branch-slug)
        ├── frontend--feat-login/      # another worktree, same branch
        ├── CLAUDE.md             # generated task context (scopes the agent)
        └── AGENTS.md             # identical content, for Codex
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

# Waiting-agent counter in the status bar
set -g status-right '!#(tmux list-windows -t tasks -F "#W" 2>/dev/null | grep -c "^!")  %Y-%m-%d %H:%M:%S'
```

## Quick start

```bash
# Create a task: worktrees for two repos on a new branch, in one folder
iwork feat/login-bug -r backend-api frontend

# Add another repo to that task later
iwork add-repo feat-login-bug -r shared-lib

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
| `IWORK_NO_TMUX` | unset | Set to skip all tmux handling (same as the `--no-tmux` flag) |
| `IWORK_NO_CONTEXT` | unset | Set to skip writing task context files (same as `--no-context`) |
| `IWORK_ASSUME_YES` | unset | Set to `1` so `install-hooks` writes without the confirmation prompt |

Leading flags `--no-tmux` and `--no-context` apply per-invocation, e.g.
`iwork --no-tmux claude feat-login-bug`.

## Updating

```bash
git -C /path/to/iwork pull
```

The symlink points at the script in the repo, so a pull is all that's needed. If the
completion output changed, open a new shell (or re-`source` your rc) to reload the
wrapper.
