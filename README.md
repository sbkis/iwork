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
- `python3` — needed for `iwork install-hooks`, and for the hook that logs PRs
  automatically. Everything else works without it.
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

Open a new shell (or `source` your rc) to pick it up. The wrapper resolves the
`iwork` binary itself when it has to, so it also works in a non-interactive
shell — an agent's `Bash` tool inherits these functions from a shell snapshot
that carries the function but not the variable that used to point at the
binary. Without this step the tool
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

# Create a task and give the agent its first prompt, so it starts without you
iwork fix/login-500 -r backend-api -m 'Look at Sentry AUTH-42 and say what breaks'

# Add another repo to that task later
iwork add-repo feat-login-bug -r shared-lib

# Remove one repo's worktree, or the whole task
iwork rm feat-login-bug -r shared-lib
iwork rm feat-login-bug

# Jump back into the task (tmux window if present, else cd)
iwork cd feat-login-bug

# Open the project master: one agent whose job is the project, not a task in it
iwork master auth-rewrite

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
│       ├── LOG.md                     # append-only, one timestamped line per entry
│       ├── TODO.md                    # captured-not-now, tagged with where and when
│       ├── history.tsv                # append-only task events (opened/detached/closed)
│       ├── agents.tsv                 # append-only session events; who is live is derived
│       └── notes/                     # anything that outlives one task
└── tasks/
    └── feat-token-api/
        ├── auth-service/
        ├── .project -> /abs/path/to/projects/auth-rewrite   # absolute
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

It deliberately does **not** point at `iwork -h`. That is ~220 lines of mostly
operator material, and it advertises `iwork rm -f`, which deletes worktrees
*including ones with uncommitted work* — not something to hand an agent that is
casting around for what it can do. `iwork project -h` is 33 lines in three
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

Ids are 32-bit, so a collision is not something you should meet. If one ever
happens, `done`/`drop` list the candidates and take `--nth <n>` rather than
refusing. Project names are matched against the spelling already on disk, so on
a case-insensitive filesystem `-p MyProj` attaches to an existing `myproj`
instead of quietly becoming a second name over the same files.

### What happens without you asking

Instructions in `CLAUDE.md` only fire if the agent decides to act on them, and
`iwork decided` has no natural moment to fire on — decisions feel like part of the
work, not an event. So three of the four paths are hooks instead (installed by
`iwork install-hooks`, which is safe to re-run and only adds what is missing):

| Hook | What it does | Judgement needed |
|---|---|---|
| `SessionStart` | Registers the session in `agents.tsv`, then runs `iwork project show` and injects the output as context | none — the agent cannot start without it |
| `SessionEnd` | Records that the session left, so it stops being listed as live | none — an event, not a judgement |
| `PostToolUse` (Bash) | Logs the PR URL when the command really is `gh pr create` | none — a URL is a fact |
| `PreCompact` | Prompts a flush right before the reasoning is discarded | the agent's, but at the right moment |
| `Stop` / `UserPromptSubmit` / `Notification` | tmux window markers, as before | n/a |

Deliberately absent: anything that *forces* a log entry. A hook that demands one
every session produces filler, and filler degrades the exact file every future
session reads. `PreCompact` says as much to the agent — record nothing if there is
nothing worth keeping.

Outside a project task every one of these prints nothing and exits 0, so
installing them globally is safe. They exit 0 on failure too — an unwritable
project directory makes a hook silent, never broken.

Entries are capped at 800 characters (`IWORK_ENTRY_MAX_CHARS`) and collapsed to
one line. `project show` prints them back and the `SessionStart` hook injects
them into every session in the project, so an unbounded entry would follow you
around forever with no supported way to remove it — `LOG.md` is append-only.

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

### Who is working on what

A project that spans a dozen tasks spans a dozen agents, and nothing recorded
which of them was where. `SessionStart` now registers the session before it
prints the brief, and `SessionEnd` records it leaving:

```bash
iwork project agents
```
```
Agents (live) in project 'auth-rewrite':
  feat-refresh-flow
    session 9e8d8f11-…  pid 42164  tmux pane %121
  feat-token-api
    session c1d195bf-…  pid 42164  tmux pane %153
    last active 4m ago
    session 1e0c8e77-…  pid 42164  tmux pane %136
```

`project show` carries the same thing in one word per task — `feat-token-api
2 agents` — so every session already knows how crowded the project is without
asking. A task can hold several agents, so this is task → *many*; a file with
one line per task would silently lose one.

A row also records the session's role. The project [master](#the-master-one-agent-whose-job-is-the-project)
is listed as `(master)` rather than under a task, because it has none — and for
the same reason it is not counted against one. The column is appended rather
than inserted, so an `agents.tsv` written before masters existed keeps every
field where it was and reads back as the task agents it recorded.

Everything else in a row comes from the environment the hook already runs in
(`CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`, `TMUX_PANE`), plus `transcript_path`
from the payload — pulled out with the same `sed` that reads the event name, so
the hook still needs no JSON parser.

**The session id is not an address.** A session is reached by the name its own
harness gives it, and that name does not derive from the session id — which is
why the tmux pane is recorded too. That is the field a coordinating agent can
match against its list of live sessions to turn a row into something it can
message. Storing the session id alone would produce a registry naming agents
that nothing could reach.

### Joining the listing to something you can message

```bash
iwork project agents --json    # one object per live session, with api_version
iwork project agents --tsv     # the same fields for awk, cut and fzf
```

Reading the listing tells you who is live. Acting on it means turning a row into
a name your harness will accept, and that is a join: match a row against your own
list of live sessions — on the session id if your harness exposes one, otherwise
on the tmux pane — and message the name that comes back.

The session id is a join key, not an address. `--json` exists so the
[master](#the-master-one-agent-whose-job-is-the-project) can do that join
mechanically instead of by eye; the columns are `task`, `role`, `session`, `pid`,
`pane`, `transcript`, `last_active_seconds`, and absent values are `null` rather
than `""` so a consumer testing for a pane does not have to know that an empty
string means there is none. `api_version` is there for the reason any
out-of-process consumer needs one — to detect skew rather than guess.

There is deliberately no `iwork say <task> "..."`. Typing into another agent's
pane is not safe, and iwork already knows it: `open_task_window` refuses to
deliver `-m` into a window that is already open, because the pane may be sitting
at a shell rather than at an agent. `agents.tsv` is better evidence than that
path has — a registered session, a pid `kill -0` confirms, a transcript whose
mtime shows activity — but none of it says the pane is at a prompt rather than
mid-tool-call, and a stray Enter into a permission dialog answers it. The join
above goes through the harness, which knows.

**Liveness is derived, never stored** — the same rule the rest of the project
memory follows. `agents.tsv` is an append-only log of registrations and
departures; `project agents` reduces it to the last row per session, drops the
ones that said they were leaving, and then drops the ones that never got the
chance:

```bash
kill -0 "$pid"   # the same tell project_lock uses for a dead lock holder
```

So a killed pane, a crash or a `kill -9` costs nothing: the row stays on disk
and stops being an answer. Pids are reused, so a row can in principle outlive
its session until something inherits its number — the pane exists precisely so
the authoritative live-session list gets the final say.

A project created before this existed has no `agents.tsv`; the first
registration writes the header itself, so there is no migration step.

Reading from the project directory itself now works without naming it, which is
where a session coordinating the others would be run:

```bash
cd ~/dev/projects/projects/auth-rewrite
iwork project agents          # the project is read from where you are standing
iwork project show
```

Standing in the project beats `IWORK_PROJECT` for the same reason a task's
`.project` link does: an env var exported once in a shell profile must not
quietly redirect the thing in front of you.

### The master: one agent whose job is the project

```bash
iwork master auth-rewrite          # or bare `iwork master` from inside the project
tmux attach -t projects            # from a second terminal, or a second client
```

Every other session iwork starts is scoped to one task, one branch, one set of
worktrees, and is told to stay inside them. That is right for the work and wrong
for the shape of the work: what the tasks should be, what order they stack in,
when one is far enough along that the next can branch off it, whether two of them
are converging on the same file. The master is the session for that.

It gets a window of its own, named after the project, in a separate `projects`
session — not a window in `tasks`. A separate session because it is the thing you
want in front of you while the tasks are not: attach to it from another terminal
or another client and leave it there. Started from outside tmux it builds that
session in the background and tells you how to reach it.

Its cwd is the project directory, which is what makes it cheap: every project
verb already resolves the project from where you are standing, so `iwork project
show`, `project agents`, `todo` and `decided` all work there with no arguments.

**Stacked PRs are the case it earns its keep on.** `--from` already builds the
chain; nothing knew the chain existed. The master does, because it chose the
split — that task B branched off A, that B's PR targets A's branch rather than
main, that when A merges the rest need rebasing. What it decides goes into the
log as it goes, so the chain survives the session that planned it. The base a
task was stacked on is recorded in `history.tsv` too, which is what lets the
stack be reconstructed after the task folders are gone.

Standing in the project directory changes three things, so the master never has
to spell them out:

| From the project directory | Why |
|---|---|
| a new task joins that project without `-p` | naming it on every line is one typo from an orphan task |
| tasks are created detached | otherwise spawning one calls `switch-client` and drags your client into the tasks session |
| `rm` and `project delete` refuse | they destroy worktrees and memory, and that stays yours |

The last one is a guardrail rather than a sandbox — `cd` out and it is gone. It
is there to catch the accident. The reason it cannot rely on the usual
confirmation is that `confirm()` reads `/dev/tty`, which a tmux pane running an
agent has: the prompt would be answered by the agent it was meant to stop.

**The master's instructions come from the `SessionStart` hook**, not from a
`CLAUDE.md` in the project directory. That is deliberate. A file would have to be
named `CLAUDE.md` to be loaded at all, and `.project` symlinks the project into
every task — so a task agent that opened it would inherit instructions telling it
to spawn tasks. Delivering the role through the hook removes that path instead of
mitigating it, and leaves nothing hand-edited for `project delete` to take with
it. The cost is that `install-hooks` is not optional here: without it the master
comes up as an ordinary agent in a directory of markdown, and says so rather than
looking fine.

`project agents` marks it as `(master)` and `project show` carries one line for
it, so every task agent can see whether a coordinator is live. It is not counted
against any task: its row has no task, by definition.

### Talking to the tasks

```bash
iwork say feat-token-api "when you get a chance, rename that field"
iwork say --urgent feat-token-api "stop — the base you branched from moved"
iwork reply "shape is opaque now; feat-refresh needs a rebase"   # from a task
iwork inbox                                                      # what is queued for me
```

A master that can only watch is a dashboard. `say` queues a message for the
agent running in a task; `reply` sends one back from a task to the master.
Neither types into anyone's terminal.

**Ordinary messages wait for a natural break.** They are read at the recipient's
next prompt, alongside whatever comes next, so work already under way is not
disturbed. Most of what a master has to say can wait that long, and a task
halfway through a refactor is the worst possible moment to redirect it.

**`--urgent` takes the agent's stopping point away.** It is delivered the instant
the current turn ends, and the agent carries straight on with it instead of
stopping. That is worth spending when letting the work continue would waste it —
the base it branched from has moved, the approach was settled elsewhere, the task
is now redundant — and not for status questions or to hurry something along.

Either way the message is queued on disk, so one sent to a task that is not
running is delivered at its next session start rather than lost.

The `Stop` path is what makes `--urgent` possible, and it is worth knowing why it
looks the way it does. Plain stdout on `Stop` goes to Claude Code's debug log and
nowhere else, so a message printed there would vanish silently. It comes back as
the *blocking reason* on exit 2 instead — the one form that both reaches the
model and keeps the agent going. That cannot loop: the drain records messages
delivered before the block is taken, so the `Stop` that fires next has nothing
urgent pending and exits 0. There is a test for exactly that, because a `Stop`
hook that always blocks is an agent that can never finish.

`inbox.tsv` follows the rules the rest of the project memory follows: append-only,
one line per event, `sent` and `delivered` as separate rows. What is pending is
derived by reducing the file on read, never stored — the same reason
`project agents` derives liveness rather than keeping a registry that starts
lying the moment a delivery is missed. Drains take the project lock, and re-read
under it, so two hooks firing at once cannot deliver the same message twice.

The recipient of a `reply` is the empty task name, which is the master's address
by construction: a task can never be addressed by an empty name, and the master
has no task. A literal `master` recipient would have collided with a task of
that name.

**What the inbox does not do is wake anyone.** An agent that has finished its
turn and is sitting at its prompt gets the message the moment it is next
prompted, but nothing prompts it — no hook fires again until something does.

That case is covered, just not by iwork. The master is itself a Claude Code
session, and Claude Code sessions on one machine can address each other by name;
`project agents --json` exists to supply the join key. The two listings share
*both* keys, which is what makes the pairing certain rather than a guess:

```
agents.tsv     session 1e0c8e77-…                        tmux pane %136
the harness    feat-project-memory-9c [1e0c8e] · idle ·  tmux tasks:@55.%136
```

The harness's short id is a prefix of `CLAUDE_CODE_SESSION_ID`, and the pane
matches exactly. So the division is: **message the session to make something
happen now, queue in the inbox to make sure it happens at all.** The inbox
outlives a session that is not running, reaches an agent whose harness offers no
messaging, and leaves a record of what was asked; session messaging wakes an
agent that is sitting idle. A master doing real work uses both.

Typing into another agent's pane remains something iwork will not do on your
behalf — see the note above. It is not needed for this.

### Joining work already in flight

```bash
iwork project add auth-rewrite feat-existing-task    # attach a task that exists
iwork project rm  auth-rewrite feat-existing-task    # detach; memory kept
iwork project list
iwork project delete -f auth-rewrite                 # deletes the memory, asks first
```

A task belongs to exactly one project. Attaching it to a second one refuses rather
than silently relinking, which would leave its history stranded in the first.
`iwork park <task> -p <project>` works too. Detaching is recorded in
`history.tsv`, so a task you detached does not keep showing up as still open.

The task name can be left out. `project add`, `project rm` and `add-repo` act on
the task whose directory you are standing in — the same inference `iwork todo`
uses, so it works from any depth inside a worktree:

```bash
cd ~/dev/projects/tasks/feat-oops/backend-api
iwork project add auth-refactor      # this task joins the project
iwork add-repo -r shared-lib         # this task gains a repo
iwork project rm                     # detaches it again; project read from the link
```

`iwork rm` is deliberately excluded: it destroys worktrees, so it wants
`--current` spelled out rather than treating a bare `iwork rm` as "this one".

One caveat when retrofitting: `project add` reads the branch from one of the
task's worktrees, so a task folder with no worktree in it is rejected.

A `~/.config/iwork/task-context.md.tmpl` created before the marker blocks
existed has no `<!-- iwork:repos -->` markers, and the template is never
overwritten — so `add-repo` had no block to refresh and the repo list in tasks
built from it stayed wrong forever. The next task creation now adds the markers
around the template's `{{REPOS}}` line and says that it did. The markers are
structural rather than content, so this is a repair rather than an opinion:
every line you wrote stays where it was, and a template that already has them
is left alone. A `{{REPOS}}` that is inlined in a sentence, or appears more than
once, is not a shape worth guessing at — those are left to you, and `add-repo`
still warns at the point it matters.

`iwork project cat` reads files inside the project only — a symlink pointing out
of it is refused. `project grep` forwards its extra arguments to ripgrep,
including paths, so that one is a convenience rather than a boundary.

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

## Starting the agent with a prompt

`-m` (`--message`) hands the agent its first prompt, so the task is already
working by the time you look at it — no waiting for the worktrees, the tmux
window and the context files before you can type:

```bash
iwork fix/login-500 -r auth-service -m 'Look at Sentry AUTH-42 and assess what is going wrong'
```

The message is passed to `claude` (or `codex`) as its initial prompt, so the
agent reads the generated `CLAUDE.md` and goes straight to work. It applies
wherever iwork starts an agent itself — creation, `park`, and `claude`/`codex`
on a task whose window is not already open:

```bash
iwork -m 'write up what changed here' park task-billing-followup
iwork -m 'continue the refactor' claude feat-login-bug   # if the window is closed
```

`-m` never types into an agent that is already running: that pane may have been
left at a shell, where free text would run as a command. When there is nothing
to start — the window or session is already open, `--no-tmux` is in play, or the
subcommand starts no agent at all — iwork says the message was not delivered
rather than dropping it silently:

```
Warning: -m was not delivered: an agent is already open in tmux window 'feat-login-bug'
```

Pair it with `--detach` (or its short form `-d`) to fire a task off and carry on
with what you were doing:

```bash
iwork fix/login-500 -r auth-service -m 'Look at Sentry AUTH-42' -d
```

Flags read in any position on a create or `add-repo` line — before the branch
name, or after the repo list — so the message can go wherever it reads best:

```bash
iwork -d -m 'triage this' fix/login-500 -r auth-service   # same thing
```

## Detached mode

`--detach` spins a task up without dragging you to it. The window is still
created and the agent still starts in it — your client just stays where it is:

```bash
iwork --detach feat/login-bug -r backend-api frontend   # create, stay put
iwork --detach claude feat-login-bug                    # start an agent, stay put
iwork --detach park task-billing-followup               # park, stay put
iwork -d feat/login-bug -r backend-api                  # -d is the short form
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
| `IWORK_PROJECTS_TMUX_SESSION` | `projects` | tmux session that holds project master windows (see [The master](#the-master-one-agent-whose-job-is-the-project)). Must differ from `IWORK_TMUX_SESSION`, or a task lookup could answer with a master |
| `IWORK_CONTEXT_TEMPLATE` | `~/.config/iwork/task-context.md.tmpl` | Template for the generated `CLAUDE.md`/`AGENTS.md` (seeded with a default on first use, then yours to edit) |
| `IWORK_PROJECT_TEMPLATE` | `~/.config/iwork/project-context.md.tmpl` | Template for the project block injected into those files (same deal: seeded once, then yours) |
| `IWORK_PROJECT` | unset | Fallback project for `todo`/`log`/`decided`/`done`/`drop`. A task's own `.project` link always wins over it; `-p` wins over both |
| `IWORK_ENTRY_MAX_CHARS` | `800` | Longest `todo`/`log`/`decided` entry. Anything longer is truncated with a marker, since `project show` prints entries back and the `SessionStart` hook injects them into every session |
| `IWORK_SHOW_LOG_LINES` | `12` | How many log entries and past tasks `iwork project show` prints. Must be a positive integer; anything else warns and falls back to 12 |
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
and the harness refuses to start unless every sandbox path is under `$TMPDIR`.

No test framework, no dependencies: it is the same bash the tool is written in.
100 tests, roughly a minute. A watchdog turns a hang into a named
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
