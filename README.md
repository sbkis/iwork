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
├── projects/                    # IWORK_PROJECTS_DIR — memory spanning many tasks
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

# Make the task part of a longer-horizon project (created on first use)
iwork feat/token-api -r auth-service -p auth-rewrite

# From inside a task: orient, capture, record — no flags needed
iwork project show
iwork todo "auth-service retries need backoff"
iwork decided "cursor pagination, not offset — offset was O(n) at 100k rows"
```

## Projects: memory across many tasks

Some work is bigger than one task. A migration spans weeks, a dozen branches and
several repos, and each new `iwork` invocation used to start an agent that knew
none of it — so you re-explained the effort every time, and anything that surfaced
mid-session but didn't belong in the current PR lived only in your head until you
remembered to act on it.

A **project** is a directory of markdown that outlives any one task:

```bash
iwork feat/token-api -r auth-service -p auth-rewrite
```

The project is created on first use (after confirming), and the task folder gets a
`.project` symlink pointing at it:

```
~/dev/projects/
├── projects/                          # IWORK_PROJECTS_DIR
│   └── auth-rewrite/
│       ├── PROJECT.md                 # curated brief: goal, where we are, constraints
│       ├── LOG.md                     # append-only, one line per entry
│       ├── TODO.md                    # captured-not-now, tagged with where it surfaced
│       ├── history.tsv                # append-only task events (opened, closed)
│       └── notes/                     # anything that outlives one task
└── tasks/
    └── feat-token-api/
        ├── auth-service/
        ├── .project -> ../../projects/auth-rewrite
        ├── CLAUDE.md                  # now carries an <!-- iwork:project --> block
        └── AGENTS.md
```

Project memory is never touched by `iwork rm`, the same guarantee branches already
get. The `.project` symlink does two jobs: it tells iwork which project a task
belongs to — which is what makes `iwork todo` work with no arguments from any
depth inside the task — and it puts the memory at a path *inside* the task
directory, so reaching it never conflicts with the agent's "stay in this
directory" scope.

### Reads through the CLI, writes only through the CLI

The generated `CLAUDE.md` / `AGENTS.md` gain a marker-delimited block naming the
project and its goal, and pointing at three read commands:

```bash
iwork project show [-n N]     # goal, live tasks, open todos, recent log, past tasks
iwork project grep <pattern>  # search the whole memory
iwork project cat notes/x.md  # read one file grep turned up
```

The files stay reachable through the symlink, and the block says so — a rule the
agent can see is false is a rule it stops believing. For **reads** the commands
are a recommendation with a real reason: `project show` is assembled and bounded,
whereas `LOG.md` grows without limit and mostly concerns other tasks. It also
means what an agent learns at startup can be improved centrally, without touching
every task's `CLAUDE.md`.

For **writes** it is a hard rule, and this one is about correctness rather than
taste. Tasks run in parallel, so several agents append to the same `LOG.md` and
`TODO.md` while you work. `iwork log` / `todo` / `decided` add a single line
atomically; an agent using an editing tool does read-modify-write and silently
drops whatever a sibling appended in between. `LOG.md` is append-only and
`TODO.md` ids are referenced from other tasks, so a rewrite loses work that isn't
its own.

None of this is enforced — `iwork project show` prints the project's absolute path
in its own header, so a determined agent can always find the files. It is a
convention with a reason the agent can check, which is the most a prompt can buy.

`PROJECT.md` is yours. The block tells the agent to report staleness rather than
fix it, so the curated brief stays curated.

### How the agent discovers the rest

The block names `iwork` as a CLI on the agent's PATH and points at
`iwork project -h`, so the verbs listed in a months-old `CLAUDE.md` are not the
only source of truth as the tool grows.

It deliberately does **not** point at `iwork -h`. That is ~180 lines of mostly
operator material, and it advertises `iwork rm -f`, which deletes worktrees
*including ones with uncommitted work* — not something to hand an agent that is
casting around for what it can do. `iwork project -h` is 28 lines in three
groups — Reading, Recording, and Managing — where the third is labelled as the
operator's, alongside a line in the block saying that creating tasks,
`add-repo`, `rm` and `park` are not the agent's to run uninvited.

Because the block is marker-delimited, one code path serves a new task, a retrofit
and a refresh, and your own edits to the rest of the file survive untouched.

### Capturing without derailing the session

From inside a task — or any directory under it — no flags are needed; the project
is read from the `.project` link:

```bash
iwork decided "cursor pagination, not offset — offset was O(n) at 100k rows"
iwork todo    "auth-service retries need backoff, hit this while wiring the client"
iwork log --shipped "auth-service#412 opened"
```

That is the answer to "something came up that doesn't belong in this PR": one
command, no context switch, and it is waiting for whichever task picks it up.

```bash
iwork done t7dc4      # close a captured todo
iwork drop t7dc4      # abandon one
```

### What happens without you asking

Instructions in `CLAUDE.md` only fire if the agent decides to act on them, and
`iwork decided` has no natural moment to fire on — decisions feel like part of the
work, not an event. So three of the four paths are hooks instead (installed by
`iwork install-hooks`, which is safe to re-run and only adds what is missing):

| Hook | What it does | Judgement needed |
|---|---|---|
| `SessionStart` | Runs `iwork project show` and injects the output as context | none — the agent cannot start without it |
| `PostToolUse` (Bash) | Spots `gh pr create` and logs the PR URL itself | none — a URL is a fact |
| `PreCompact` | Prompts a flush right before the reasoning is discarded | the agent's, but at the right moment |
| `Stop` / `UserPromptSubmit` / `Notification` | tmux window markers, as before | n/a |

Deliberately absent: anything that *forces* a log entry. A hook that demands one
every session produces filler, and filler degrades the exact file every future
session reads. `PreCompact` says as much to the agent — record nothing if there is
nothing worth keeping.

Outside a project task every one of these prints nothing and exits clean, so
installing them globally is safe.

Each of these appends a single line with one `printf`, which is atomic — so agents
working in parallel tasks cannot clobber each other, and capture never waits on a
lock. Only the rewrite operations (`done`, `drop`) take one.

### Live state is never cached

Which tasks exist, what branch they are on and what their agents are doing is read
from the filesystem and tmux on every call, exactly as `iwork list` does. Nothing
about it is stored, so nothing about it can go stale: delete a task folder by hand
and `project show` simply stops listing it as live.

`history.tsv` records only what *cannot* be derived once a task folder is gone —
the branch, the repos, when it opened and closed. It is append-only, one line per
event, so it never needs rewriting and two tasks closing at once cannot corrupt it.

### Joining work already in flight

```bash
iwork project add auth-rewrite feat-existing-task    # attach a task that exists
iwork project rm  auth-rewrite feat-existing-task    # detach; memory kept
iwork project list
iwork project delete -f auth-rewrite                 # deletes the memory, asks first
```

A task belongs to exactly one project. Attaching it to a second one refuses rather
than silently relinking, which would leave its history stranded in the first.
`iwork park <task> -p <project>` works too.

## Branch tracking

A task branch is created from `origin/main` (or whatever `origin/HEAD` points at),
but **without** an upstream. Git's default would make `origin/main` the upstream of
the new branch, so every `git status` and shell prompt would report the branch as
ahead of — and behind — a branch it has nothing to do with, before it has ever been
pushed:

```
## feat/login-bug...origin/main [ahead 1]     # git's default
## feat/login-bug                             # what iwork creates
```

The branch still *starts* from the base branch; only the upstream link is skipped.
Push as usual when you're ready, and that sets a real upstream:

```bash
git push -u origin HEAD        # -> origin/feat/login-bug
```

Worktrees created before this change still carry the old upstream. Clear it from
inside the worktree:

```bash
git branch --unset-upstream
```

## Stacking a task on earlier work

By default a task branches from `origin/main`. `--from` starts it from earlier
work instead — another task, or any branch:

```bash
iwork feat/step-two --from feat-step-one -r backend-api frontend
iwork --from feat-step-one feat/step-two -r backend-api      # also fine, leading
iwork add-repo feat-step-two --from feat-step-one -r shared-lib
```

Per repo, iwork uses the first of these that exists and reports which base each
repo got:

1. the branch checked out in that repo's worktree in the named task
2. a local branch of that name
3. `origin/<name>`
4. anything else git resolves there — `origin/x` spelled out, a tag, a SHA

So the base needs **no worktree and no live task**. `rm` keeps branches, so a task
you have already torn down still works as a base, and so does an ordinary branch
you never made a task for:

```bash
iwork feat/next --from feat/step-one -r api     # branch of a deleted task
iwork feat/next --from spike/local -r api       # plain local branch
iwork feat/next --from release/2026 -r web      # remote-only branch
iwork feat/next --from v1.2.3 -r api            # tag
```

A stacked task can be wider than its base. Repos the base doesn't cover fall back
to their own base branch and say so:

```
Warning: shared: nothing named 'feat-step-one' here; using the repo's base branch instead
  -> api (branch: feat/step-two, from feat/step-one)
  -> web (branch: feat/step-two, from feat/step-one)
  -> shared (branch: feat/step-two, from origin/main)
```

If the base task has uncommitted changes, the new branch starts from its last
commit — iwork warns rather than guessing what you meant.

Two things to know:

- **The stack does not track.** Branching is a one-time starting point: if the base
  branch gains commits later, stacked tasks don't follow. Rebase yourself
  (`git rebase feat/step-one`) if you need to catch up.
- **Agents are told.** A stacked task's `CLAUDE.md`/`AGENTS.md` says what it was
  branched from, so the agent knows that work is already in its history and
  shouldn't be built again. No template change needed: iwork appends a short
  `## Base` section. If you'd rather place it yourself, put `{{BASE}}` in
  `~/.config/iwork/task-context.md.tmpl` — e.g. ``all on branch `{{BRANCH}}`,
  branched from {{BASE}}:`` — and the appended section is skipped. Tasks without
  `--from` get no `## Base` section at all.

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
repo) and, when no `-r` is given, the generated agent context (`CLAUDE.md`,
`AGENTS.md`, `.claude/`), the task folder, and the task's tmux window or session.
It shows what it is about to do and asks for confirmation first.

Things it will not do:

- **Delete branches.** The branch survives every removal; only the working copy
  goes away.
- **Throw away uncommitted work.** If any target worktree is dirty, `rm` names it
  and stops. Pass `-f` to remove it anyway (which also skips the prompt).
- **Delete files it didn't create.** Anything in the task folder other than the
  worktrees and that generated agent context keeps the folder alive; `rm` warns
  and lists what stayed behind.

### Orphaned worktrees

If a worktree directory is renamed with plain `mv` instead of `git worktree move`,
git eventually prunes the registration it can no longer find, leaving a directory
with a dangling `.git`. git can tell you nothing about such a directory — not even
whether it holds uncommitted work — so `rm` reports it as orphaned and refuses
without `-f`:

```
  - accounting-api  (orphaned: registration gone, deleted as a plain directory)
Error: orphaned directories cannot be checked for uncommitted work; re-run with -f to delete them
```

With `-f` it is deleted as a plain directory. To rename a worktree without
creating one of these, use `git worktree move` (see the migration snippet above).

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
| `IWORK_PROJECTS_DIR` | `$IWORK_REPO_DIR/projects` | Where project memory lives (see [Projects](#projects-memory-across-many-tasks)) |
| `IWORK_TMUX_SESSION` | `tasks` | tmux session that holds task windows |
| `IWORK_CONTEXT_TEMPLATE` | `~/.config/iwork/task-context.md.tmpl` | Template for the generated `CLAUDE.md`/`AGENTS.md` (seeded with a default on first use, then yours to edit) |
| `IWORK_PROJECT_TEMPLATE` | `~/.config/iwork/project-context.md.tmpl` | Template for the project block injected into those files (same deal: seeded once, then yours) |
| `IWORK_PROJECT` | unset | Default project for `todo`/`log`/`decided`/`done`/`drop` when you are not inside a task |
| `IWORK_SHOW_LOG_LINES` | `12` | How many log entries and past tasks `iwork project show` prints |
| `IWORK_EDITOR` | `nvim` | Editor started in each repo window under `--big`; run as a command line with the worktree appended |
| `IWORK_NO_TMUX` | unset | Set to skip all tmux handling (same as the `--no-tmux` flag) |
| `IWORK_NO_CONTEXT` | unset | Set to skip writing task context files (same as `--no-context`) |
| `IWORK_DETACH` | unset | Set to never switch to the task window (same as `--detach`) |
| `IWORK_BIG` | unset | Set to give every task its own session (same as `--big`) |
| `IWORK_ASSUME_YES` | unset | Set to `1` to skip confirmation prompts (`install-hooks`, `rm`, creating a project) |

Leading flags `--no-tmux`, `--no-context`, `--detach` and `--big` apply
per-invocation, e.g. `iwork --no-tmux claude feat-login-bug`.

## Tests

```bash
tests/run.sh            # everything
tests/run.sh todo       # only tests whose name matches 'todo'
KEEP=1 tests/run.sh     # leave the sandbox behind to poke at
```

Every test builds a throwaway tree under `$TMPDIR`: fake repos with local
`origin` remotes, a fake tasks dir, a fake projects dir, a fake `HOME`, and — for
the tmux tests — a tmux server on its own socket via `TMUX_TMPDIR`. Nothing can
reach your real `IWORK_REPO_DIR`, your real `~/.config`, or a live tmux session,
and the harness refuses to start if any sandbox path resolves outside `$TMPDIR`.

No test framework, no dependencies: it is the same bash the tool is written in.
The whole suite takes about 25 seconds. A watchdog turns a hang into a named
failure (`SUITE_TIMEOUT` to tune it), which matters because `confirm()` reads
`/dev/tty` — a test that forgets `-f` or `IWORK_ASSUME_YES` would otherwise block
your terminal with no clue which one did it.

## Updating

```bash
git -C /path/to/iwork pull
```

The symlink points at the script in the repo, so a pull is all that's needed. If the
completion output changed, open a new shell (or re-`source` your rc) to reload the
wrapper.
