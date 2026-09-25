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
(`*task` = busy, `!task` = waiting for you) and put the same marker on the
session names, derived from the windows inside them. Idempotent; shows the change
and asks before writing.

```bash
iwork install-hooks              # edits ~/.claude/settings.json
iwork install-hooks path/to/settings.json   # or a specific settings file
```

### 6. Recommended tmux config (optional)

iwork keeps its windows in sessions of its own — `tasks` for loose tasks, one
`projects-<project>` per project, one `tasks-<task>` per `--big` task (see
[Which session holds what](#which-session-holds-what)). These `~/.tmux.conf`
additions make it easy to move between your regular sessions and iwork's, and
surface how many agents are waiting:

```tmux
setw -g automatic-rename off        # let iwork own the task window names

bind Tab switch-client -l           # prefix+Tab: toggle last session

bind T switch-client -t tasks       # prefix+T: jump to the tasks session

# Waiting-agent counter in the status bar. -a covers every session, so it also
# counts agents inside per-task `tasks-*` sessions (see Big tasks below).
set -g status-right '!#(tmux list-windows -a -F "#W" 2>/dev/null | grep -c "^!")  %Y-%m-%d %H:%M:%S'
```

Only `iwork` marks names with `!`, so counting across all sessions is safe. Count
**windows**, not sessions.

Then add the tmux-side integration, which `iwork` will write for you:

```bash
iwork --tmux-config
```

It prints three things: a status line and a session picker that show each
session's agent state, and a `session-created` hook that repairs a split session.
All three read `@iwork_state` rather than the session's name — see
[Session state without renaming](#session-state-without-renaming) for why that
matters.

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

# After a tmux server died: restart every agent where it belongs
iwork resurrect -n
iwork resurrect

# Relink every task's .claude/skills from its worktrees
iwork skills

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
| `Stop` / `UserPromptSubmit` / `Notification` | tmux window markers, plus the session marker derived from them | n/a |

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

#### What the markers mean

A **window** speaks for one agent, and keeps its marker until that agent moves:
`*feat-x` while it works, `!feat-x` once it wants you.

A **session** speaks for all the agents in it, so its state is not stored — it is
derived from its windows on every hook, and `!` outranks `*`. It is published as
the `@iwork_state` option on the session rather than written into its name:

| `@iwork_state` | Meaning |
|---|---|
| `!` | at least one agent in there is waiting for you |
| `*` | one is working, none is waiting |
| empty | neither — nothing in there wants anything |

That holds for every session iwork owns: the shared `tasks`, each
`projects-<project>` (its master and its tasks counted together), and a `--big`
task's own `tasks-<task>`. Repo windows under `--big` hold an editor rather than
an agent, so they never count. Being derived is what lets it *clear* — a window's marker can
only be replaced by the next event from that same agent, while a session recomputes
from what is actually there. `iwork rm` re-derives it too, so closing the last
waiting task drops the `!` immediately rather than leaving the name lying.

Reading it from an option rather than the name is what keeps session names stable
for everything else — see
[Session state without renaming](#session-state-without-renaming). Everything
inside `iwork` (`list`, `cd`, `claude`, `codex`, `add-repo`, `rm`) matches a
session name with any marker ignored regardless, so a tree marked by an older
version, or by `IWORK_SESSION_MARKERS=on`, keeps working.

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

### Culling: how a master tears down its own tasks

`rm` is the operator's, and for a reason worth stating: it destroys worktrees
that may hold uncommitted work in a window nobody is watching, and the
confirmation that would normally catch that is no help against an agent —
`confirm()` reads `/dev/tty`, which a pane running an agent has, so the agent
answers its own prompt.

`iwork cull` is the part a master can be trusted with, and it is trusted for what
it **refuses** rather than for anything it asks:

```bash
iwork cull -n                    # every task, with what would stop each
iwork cull feat-a feat-b         # these two
iwork cull --all                 # every one that is eligible
```

A task goes only when git can give all of it back. It is kept, and the reason
named, when:

- a worktree has **uncommitted changes** (untracked files included)
- the task folder holds a file that **was never committed** — a note written at
  the task root rather than inside a repo
- a directory is **orphaned**, so git cannot say what is in it
- **an agent is working in it** (`*`), since culling takes the window and
  whatever is running in it

Branches survive, exactly as they do under `rm`, so a culled task comes back:

```bash
iwork feat/login-bug --from feat/login-bug -r backend-api
```

**Committed-but-unpushed work is deliberately not a blocker.** The branch still
has those commits once the worktree is gone. An earlier version refused on it,
which sounded careful and was merely wrong — it kept most of a real project's
tasks to protect against a risk that does not exist.

Naming the tasks is the normal way in. A master's tasks are mostly tasks it is
still using, so taking the lot has to be spelled out with `--all`.

### And `rm` itself, from a project directory

`rm` now runs there too — only `-f` is refused:

```bash
iwork rm feat-login-bug       # works; stops dead on anything dirty
iwork rm -f feat-login-bug    # refused from a project directory
```

`-f` is the flag that turns `rm` into something it must never be for an agent: it
drops uncommitted work and skips the confirmation. Refusing it is what actually
protects, since the confirmation never could.

### The master: one agent whose job is the project

```bash
iwork master auth-rewrite            # or bare `iwork master` from inside the project
tmux attach -t projects-auth-rewrite # from a second terminal, or a second client
```

Every other session iwork starts is scoped to one task, one branch, one set of
worktrees, and is told to stay inside them. That is right for the work and wrong
for the shape of the work: what the tasks should be, what order they stack in,
when one is far enough along that the next can branch off it, whether two of them
are converging on the same file. The master is the session for that.

It gets the **first window of the session its project owns** — `projects-claims`
for project `claims` — named after the project, with the tasks it spawns in the
windows behind it. A session per project because a project is the unit you attend
to: attach to it from another terminal or another client and leave it there, move
between the master and its tasks with `prefix + n`, and read one row in the
session list to know whether anything in that project wants you. Started from
outside tmux it builds the session in the background and tells you how to reach
it. `project delete` takes the session with it.

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
| tasks are created detached | otherwise spawning one calls `switch-client` and moves your client off the master's own window |
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

A master that can only watch is a dashboard. Directing a task is done with Claude
Code's own session messaging, not with anything iwork adds — iwork's job is to
tell you *which* session is which:

1. `ListAgents` — every live session, the name it answers to, whether it is idle
   or working, and its tmux pane
2. `iwork project agents --json` — the pane for each task in this project
3. pair on the pane, then `SendMessage` to the name
4. `ListAgents` again — that session should have flipped to working

```
agents.tsv     session 1e0c8e77-…                        tmux pane %136
the harness    feat-project-memory-9c [1e0c8e] · idle ·  tmux tasks:@55.%136
```

Pair on the **pane**: it is recorded on both sides, matches exactly, and is the
only key that separates two agents working in the same task. The short id beside
the name is a prefix of `CLAUDE_CODE_SESSION_ID`, so it confirms a pairing, and
it is what a harness wants when two sessions share a name. Step 4 is not
ceremony — an agent that is idle looks exactly like one that got your message and
ignored it.

Most agents are idle most of the time. One that has finished its turn is sitting
at its prompt waiting to be spoken to, and nothing else will start it again — no
hook fires there until something prompts it.

**For a task with no session running, don't message — start one**, with the
instruction as its first prompt:

```bash
iwork --detach -m "rebase onto feat-zero, the shape changed" claude feat-token-api
```

**For anything that should outlive the conversation, use the log.** `iwork
decided` and `iwork todo` are read by every session on the way in, which is a
guarantee no message queue offers. iwork briefly had one — `say`/`reply`/`inbox`,
backed by an append-only `inbox.tsv` and delivered by the hooks — and it was cut
before it shipped. Every case it covered was already covered better: a live agent
by `SendMessage`, one that is not running by `claude -m`, and anything durable by
the project log it duplicated.

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

### When a task's repos are on different branches

A task is meant to be one branch across several repos, and `add-repo` reads that
branch off the worktrees already there. Nothing enforces it, though — an agent
can commit a worktree onto a branch of its own — and once the repos disagree
there is no single branch for a new worktree to follow:

```
Error: task 'feat-claims' has worktrees on more than one branch, so there is no
  single branch to follow:

    accounting-api    feat/claim-case-queue
    rent-api          feat/org-claim-case-queue
    rent-frontend-v2  feat/claims-feedback

  Pick one for the new worktree, or name another:
    iwork add-repo feat-claims -b <branch> -r email-templates
```

`-b` names the branch instead of deriving it:

```bash
iwork add-repo feat-claims -b feat/org-claim-case-queue -r email-templates
iwork add-repo feat-claims -b feat/something-new -r email-templates
```

The branch need not be one the task is already on — `-b` is equally the way to
bring a repo in on a branch of its own, which is how a task ends up mixed in the
first place. It applies to `add-repo` only; when creating a task the branch is
the first argument.

`project add` hits the same wall, because a project records one branch per task.
There `-b` does not apply: put the worktrees on one branch first, or attach a
task that already is.

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

## Skills from the worktrees

Claude Code loads a project's skills from the directory the session is rooted in.
An iwork task is rooted **above** its worktrees, so a skill defined in one of them
was simply out of scope for the agent iwork starts:

```
tasks/feat-login/          <- the session is rooted here
├── backend-api/
│   └── .claude/skills/    <- never loaded
└── frontend/
    └── .claude/skills/    <- never loaded
```

The failure is quiet and reads like the wrong thing. A repo's `AGENTS.md` saying
*"invoke the translator-skill before calling a task complete"* is not being
ignored — it cannot be followed, and `Skill(translator-skill)` answers
`Unknown skill`, which looks like the skill is broken rather than out of reach.

So a task now gets a `.claude/skills/` of its own, holding a link to every skill
in every worktree:

```
tasks/feat-login/.claude/skills/
├── db-migrations      -> ../../backend-api/.claude/skills/db-migrations
└── translator-skill   -> ../../frontend/.claude/skills/translator-skill
```

It is rebuilt whenever iwork starts an agent for the task, so a repo that gains
or drops a skill is picked up without anything being re-created. Only links iwork
made are replaced — a directory you put there by hand is yours and stays.

### Healing tasks that already exist

Linking happens whenever iwork starts an agent, which only ever fixes the task
you are about to work in. A tree full of tasks made before this existed would
each wait their turn, and one you never reopen would wait forever. `iwork skills`
walks the whole tasks directory instead — the same list `iwork list` prints:

```bash
iwork skills -n     # what it would link, per task
iwork skills        # do it
iwork skills feat-login-bug   # just this one
```

```
feat-claims-milestone-5   35 skill(s)
    'code-review-skill' comes from more than one repo -> <repo>-code-review-skill
feat-guarantee-redesign   35 skill(s)
feat-photo-write-path     7 skill(s)
mobile-listing-real-estate  -
```

It is idempotent, so running it on a healthy tree changes nothing.

### When two repos define the same skill

This is the case worth being careful about. If `backend-api` and `frontend` both
define `code-review-skill`, they are different skills with the same name, and
linking either one under the bare name would hand the agent the wrong repo's
rules **without saying so** — worse than the unknown-skill error it replaces,
because it looks like it worked.

Both are linked with their repo in front instead, and no bare name is invented:

```
backend-api-code-review-skill   -> backend-api/.claude/skills/code-review-skill
frontend-code-review-skill      -> frontend/.claude/skills/code-review-skill
```

iwork says which names this happened to. `code-review-skill` on its own stays
unknown, which is the honest answer: there are two, and only you know which one
the change in front of you needs.

### The limit

This fixes sessions rooted at the task, which is where `iwork` starts them. A
session you start by hand *inside* a worktree is rooted there and sees that
repo's skills only — the same as any ordinary checkout. Run agents from the task
root and everything is in scope.

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
from **outside** tmux, creating whichever session the task belongs in
([which one](#which-session-holds-what)) in the background.

Pick the task up whenever you like with `iwork cd <task>`, or watch it from
`iwork list` — the `*` / `!` markers report whether the agent is busy or waiting
for you. Set `IWORK_DETACH=1` in your config to make this the default.

## Which session holds what

A task's window goes where its **project** says, not where it was created from:

```
session tasks                     tasks that belong to no project
|- window "feat-login-bug"        claude | shell
'- window "chore-bump-deps"

session projects-claims           one per project
|- window "claims"                the master, always the first window
|- window "feat-response"         a task of that project
'- window "feat-askilnadur"       another

session tasks-feat-big-thing      a --big task owns a whole session
|- window "feat-big-thing"        the agent
'- window "backend-api"           one per repo: nvim | shell
```

Before this, every task went into `tasks` — so a master spawning five of them
buried the two you were working on yourself. Now the shared session means one
thing: **tasks that belong to no project.**

The rule is a function of the task, which is what keeps it predictable:

- `iwork feat/x -r backend -p claims` lands in `projects-claims` whether you
  typed it or its master did. Who created it is not part of the address.
- `iwork project add claims feat-x` on a task that is already running **moves its
  window** into the project's session, and `project rm` moves it back out. The
  session is created if it is not there yet, and destroyed by tmux when its last
  window leaves.
- `cd`, `claude`, `codex`, `list` and `rm` look for a task's window in its own
  session, then its project's, then the shared one — and then across every
  session iwork owns, so a window that has drifted is still found rather than
  duplicated.
- `--big` still wins: a task with its own session keeps it, project or no
  project.

### Moving an existing setup over

Nothing on disk changes: project directories, `.project` links, `history.tsv`,
`agents.tsv` and the task folders are untouched by this. The only thing that
drifts is live tmux windows, and one command per project settles it:

```bash
iwork master claims     # the project's own session, assembled
```

That does two things, and says so line by line:

- **Adopts a master left in the old shared `projects` session.** That window is
  the real master — an agent already holding the project's brief — so it is moved
  into `projects-claims` as the first window rather than left behind for a second
  master to duplicate. The old `projects` session disappears once its last window
  leaves, which is tmux's rule, not iwork's.
- **Gathers the project's tasks** out of the shared session into
  `projects-claims`. Tasks belonging to no project are left alone.

Neither is migration-only: gathering repairs any later drift the same way, and
both are no-ops once every window is where it belongs — so re-running `iwork
master` is always safe. To move a single task's window instead, re-run `iwork
project add <project> <task>` on a task that is already attached.

Two things it deliberately does not do. It never moves **the window you are
looking at** — that would make your client jump to whatever was left behind — and
it never touches a `--big` task, which owns its session by design. Nothing needs
doing for the windows it skips: every lookup searches the project's session, the
shared one, and then everywhere else iwork owns, so a window that stays put is
still found rather than duplicated.

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
- **The session's state is published too**, as `@iwork_state` on the session —
  the session list (`prefix + s`) shows names and nothing else, so a task that
  owns a session would otherwise be the one place the state did not reach. See
  [Session state without renaming](#session-state-without-renaming). Everything
  that looks a session up by name (`cd`, `claude`, `codex`, `add-repo`, `rm`,
  `list`) tolerates a marker regardless, so an older marked tree keeps working.
- **`cd`, `claude`, `codex`** find a task wherever its window is — its own
  session, its project's, or the shared one — whether or not you pass `--big`
  again.
- **`add-repo`** adds a window for the new repo to a live session.
- **`rm`** kills the whole session, and says so before it does — anything unsaved
  in those editors goes with it.
- **`--big --detach`** builds the session without moving you into it, and works
  from outside tmux entirely.

If a task is already open as a plain window somewhere — the shared session or its
project's — `--big` will not start a second agent for it in a new session; close
that window first.

Set `IWORK_BIG=1` in your config to make every task work this way.


## Recovering from a dead tmux server

When the tmux server dies it takes every agent with it and nothing else. The
worktrees are still on disk, and Claude keeps its transcripts per directory, so
the conversations are not lost either — only the processes that were having
them. If you run a session restorer (tmux-resurrect, continuum) you get the
window layout back, but every pane comes up as a bare shell.

```bash
iwork resurrect -n     # what it would do
iwork resurrect        # do it
```

It reads the tasks directory as the truth and makes tmux match it again:

- **Closes windows whose task is gone.** A restorer replays whatever snapshot it
  has, so it brings back windows for tasks you tore down since — pointing at
  directories that no longer exist.
- **Restarts the agent in every task window that came back empty**, in place, so
  the window keeps its number and its neighbours.
- **Opens a window for every task that has none**, where that task belongs — the
  shared session, or its project's.
- **Puts each project back together**: adopts a master left in the old shared
  `projects` session and gathers the project's task windows into its session,
  the same repair `iwork master` does, for every project at once.

Agents come back with `claude --continue`, which resumes the last conversation in
that directory. Pass `--fresh` to start them cold instead. A task whose directory
has no conversation yet simply reports that and leaves you at a prompt.

### What it will not touch

Nothing with a process in it. A pane already running an agent is left alone, a
pane running an editor is reported rather than typed into, and a window is never
closed while anything is running in it. That makes `resurrect` safe to re-run,
and safe to run when only part of the tree is broken.

`-n` prints the whole plan and changes nothing. It is worth running first: it is
the only way to see which windows it considers leftovers before they close.

### Big tasks have to be named

Which tasks were `--big` is recorded in the session layout and nowhere on disk.
A dedicated session that survived is believed, but one that died cannot be
guessed at, so name it:

```bash
iwork resurrect --big feat-big-thing
```

Everything else comes back as an ordinary window.

### Masters are restarted, never created

A master is a standing agent holding its project's brief, so starting a batch of
them for projects that never had one is not a restore. `resurrect` restarts the
masters that are there, and names the projects that have none so you can start
one yourself with `iwork master <project>`.

### Session state without renaming

Earlier versions wrote a session's agent state into its **name** — `!projects-x`
when something in there wanted you, `*projects-x` when something was working.
It read well in `prefix + s`, and it was the wrong place to put it.

A session's name is its identity to every other tool. Renaming it constantly
means anything that looks a session up by the name it last saw will miss it:
keybindings, scripts, session restorers, and session switchers. Switchers are
the worst case, because several of them *create* whatever they cannot find.
[tmux-sessionx](https://github.com/omerxx/tmux-sessionx) does exactly this:

```bash
if ! tmux has-session -t="$target" 2>/dev/null; then
    ...
    tmux new-session -ds "$target" -c "$z_target" -n "$z_target"
```

Render the list, pick a session, and if an agent changes state in between, the
name you picked no longer exists — so you get a brand-new empty session under
the stale name, sitting next to the real one. That is where duplicate sessions
come from, and nothing inside iwork can prevent it, because the instability *is*
the feature.

So the state lives in a tmux option instead. `@iwork_state` is set on every
iwork session — `!`, `*`, or empty — and the name never moves:

```tmux
# in the status line, for the session you are looking at
set -g status-right '#{?#{==:#{@iwork_state},!},[needs you] ,}#{session_name}'

# in the session picker, which is where you actually go looking
bind-key S choose-tree -Zs -O name \
  -F '#{?session_format,#{@iwork_state}#{session_name}: #{session_windows} windows,#{window_name}}'
```

`iwork --tmux-config` prints both, ready to paste.

**Window** names still carry their marker. Those are iwork's own — it creates the
windows and nothing else looks them up by name — so the counter above still
works, and `iwork list` still reports per-task state.

#### Putting the marker back (unstable)

```sh
IWORK_SESSION_MARKERS=on
```

in `~/.config/iwork/config` restores the old behaviour. It is off by default and
labelled unstable for the reason above: with it on, session names move under
other tools and duplicates become possible again. If you want it anyway, take
the `session-created` hook from `iwork --tmux-config` as well — it folds a split
back together the moment a switcher creates one:

```tmux
set-hook -g session-created 'run-shell -b "iwork --fold-sessions"'
```

Turning the setting back off is enough to undo it: the next time iwork touches a
marked session, the name converges back to the plain one.

### Duplicate sessions

A marked session does not reserve its plain name: to tmux, `!tasks` and `tasks`
are two different sessions. That matters because tmux refusing a duplicate name
is what normally makes two racing `iwork` invocations safe — the loser is told
the name is taken and uses the session that is already there. The marker removes
that protection, so an invocation that checked for a session just before a marker
landed on it can go on to build a second one for the same thing. From then on the
two drift: half a project's windows in one, half in the other.

There is no way to make check-then-create atomic in tmux, so the split is
repaired rather than prevented. Any command that is about to use one of iwork's
sessions folds a split it finds first — every window into whichever session has
been there longest, then the drained one goes with its last window, and the
marker is re-derived. Nothing that was open is lost, and `resurrect` does the
same sweep across every session at once:

```bash
iwork resurrect -n    # names any split it finds, changes nothing
iwork resurrect
```

### Stale status markers

The `*` / `!` markers on window and session names are written by the Claude Code
hooks, so a name freezes at whatever the agent's state was when the server died
— `iwork list` will report `!waiting` for an agent that is not running at all.
Restarting the agent does not clear the marker by itself; the next hook event
does, which is the first time that agent changes state.


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

### Removing the task you are standing in

`rm` works from inside the task's own tmux window, or from inside the session a
`--big` task owns. It used to refuse that case — killing the window would have
killed the `iwork` process running in it, so the task folder never got removed —
and told you to close the window yourself, which left a window pointing at a
directory that was half gone.

It now finishes the job and closes the window last:

1. Everything else in the window (or every other window in the session) is killed
   at the usual moment, so no editor or agent is left alive to write the task
   folder back up while it is being deleted.
2. The worktrees, the context files and the folder go.
3. Your client is moved somewhere that will outlive the kill — another window in
   the same session if there is one, otherwise another session — and only then
   does the window or session you were in go with it.

`rm` says where it put you. If nothing else is open in tmux at all, there is
nowhere to go and the client detaches, which is the same thing that would happen
if you closed the last window by hand.

`project delete` behaves the same way when you run it from inside the project's
own session.

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
| `IWORK_TMUX_SESSION` | `tasks` | tmux session for tasks that belong to no project, and the prefix for a `--big` task's own session (`tasks-<task>`) |
| `IWORK_PROJECTS_TMUX_SESSION` | `projects` | prefix for the session each project owns (`projects-<project>`), holding its master and its tasks (see [The master](#the-master-one-agent-whose-job-is-the-project)) |
| `IWORK_CONTEXT_TEMPLATE` | `~/.config/iwork/task-context.md.tmpl` | Template for the generated `CLAUDE.md`/`AGENTS.md` (seeded with a default on first use, then yours to edit) |
| `IWORK_PROJECT_TEMPLATE` | `~/.config/iwork/project-context.md.tmpl` | Template for the project block injected into those files (same deal: seeded once, then yours) |
| `IWORK_PROJECT` | unset | Fallback project for `todo`/`log`/`decided`/`done`/`drop`. A task's own `.project` link always wins over it; `-p` wins over both |
| `IWORK_ENTRY_MAX_CHARS` | `800` | Longest `todo`/`log`/`decided` entry. Anything longer is truncated with a marker, since `project show` prints entries back and the `SessionStart` hook injects them into every session |
| `IWORK_SESSION_MARKERS` | `off` | **Unstable.** `on` writes the agent marker into session *names* as well as window names. Makes session names unstable for every other tool — see [Session state without renaming](#session-state-without-renaming) |
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
