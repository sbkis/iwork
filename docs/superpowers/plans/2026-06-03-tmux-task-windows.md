# iwork tmux Task Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One tmux window per iwork task in a dedicated `tasks` session, named after the task folder, with live Claude Code agent status markers in the window name.

**Architecture:** Everything stays in the single `iwork` bash script. New tmux helper functions (find-or-create task windows in the `tasks` session), tmux-aware behavior in all task-entry commands, a `--hook` handler wired to Claude Code hooks via a new `install-hooks` subcommand, and a status column in `list`.

**Tech Stack:** bash 3.2-compatible shell script (macOS), tmux, python3 (only for `install-hooks` JSON editing).

**Spec:** `docs/superpowers/specs/2026-06-03-tmux-task-windows-design.md`

---

## Important context for the implementer

- The entire tool is ONE executable bash script: `/Users/sbk/dev/igloo/iwork/iwork`. There is no test suite; verification is manual, using an **isolated tmux server** (`tmux -f /dev/null -L iwork-test ...`) so the user's real tmux is never touched.
- Task windows live in a dedicated tmux session (default `tasks`, overridable via the `IWORK_TMUX_SESSION` env var) — NOT the session the user is currently in. This keeps the user's per-repo `igloo` session at a stable window count.
- The isolated test server is detached (no attached client), so `switch-client` calls fail there; that is why every `switch-client` is `|| true` best-effort. Verifications therefore assert the *session's current window* (`tmux display-message -t tasks ...`), not the client's.
- macOS ships bash 3.2. Do NOT use associative arrays, `${var,,}`, `readarray`, or other bash-4-isms. The existing script is bash-3.2-clean; keep it that way.
- The script uses `set -euo pipefail`. Any command that may legitimately fail must be guarded (`|| true`, `if ...`, etc.). This matters especially in the `--hook` handler, which must NEVER exit non-zero or print errors (a broken hook would disrupt the agent).
- Line numbers below refer to the script as of commit `4b6188c`. If they have drifted, locate the quoted code instead.
- Per the user's global rules: commit messages are plain `type: description`, NO emoji, NO Co-Authored-By trailers of any kind.

## Manual test harness (used by several tasks)

Each task's verification that needs tmux starts with this setup and ends with the teardown. Run these in a normal terminal (inside or outside your real tmux — the `-L iwork-test` socket isolates everything).

**Setup:**

```bash
IWORK=/Users/sbk/dev/igloo/iwork/iwork
TD="$(mktemp -d)"
mkdir -p "$TD/igloo/AAWORKTREES/test-task" "$TD/igloo/AAWORKTREES/other-task" "$TD/bin"
printf '#!/bin/sh\necho CLAUDE-STARTED "$@"\nexec cat\n' > "$TD/bin/claude"
chmod +x "$TD/bin/claude"
git init -q "$TD/igloo/repo-a"
git -C "$TD/igloo/repo-a" commit -q --allow-empty -m init
tmux -f /dev/null -L iwork-test new-session -d -s t -x 200 -y 50
tmux -L iwork-test send-keys -t t:0 "export IGLOO_DIR='$TD/igloo' PATH='$TD/bin:'\$PATH" Enter
```

Notes:
- `$TD/bin/claude` is a fake agent: prints `CLAUDE-STARTED` and blocks on `cat`, so we can assert it launched and in which pane.
- `IGLOO_DIR` is exported in the test pane; Task 1 makes the script honor it.
- `-f /dev/null` gives default tmux config: window/pane base index 0, no plugins.
- The `tasks` session is created by iwork itself on first use (on this isolated server).

**Teardown:**

```bash
tmux -L iwork-test kill-server 2>/dev/null || true
rm -rf "$TD"
```

---

### Task 1: tmux helper functions, env-overridable IGLOO_DIR, --no-tmux flag

**Files:**
- Modify: `iwork:4` (IGLOO_DIR), after `iwork:5` (new globals), after `is_registered_worktree_path` (~line 685, new functions), dispatch case block (~line 691)

- [ ] **Step 1: Make IGLOO_DIR env-overridable and add new globals**

Replace (line 4):

```bash
IGLOO_DIR="$HOME/dev/igloo"
```

with:

```bash
IGLOO_DIR="${IGLOO_DIR:-$HOME/dev/igloo}"
```

And after line 6 (`SELF_PATH=...`), add:

```bash
TASKS_SESSION="${IWORK_TMUX_SESSION:-tasks}"
IWORK_NO_TMUX=""
```

- [ ] **Step 2: Add tmux helper functions**

Insert after the closing `}` of `is_registered_worktree_path` (line 685), before the `if [[ $# -eq 0 ]]` dispatch:

```bash
in_tmux() {
  [[ -n "${TMUX:-}" ]]
}

tmux_enabled() {
  in_tmux && [[ -z "$IWORK_NO_TMUX" ]]
}

find_task_window() {
  local folder="$1"
  local window_id=""
  local window_name=""

  while IFS=' ' read -r window_id window_name; do
    if [[ "${window_name#[*!]}" == "$folder" ]]; then
      printf '%s\n' "$window_id"
      return 0
    fi
  done < <(tmux list-windows -t "=$TASKS_SESSION" -F '#{window_id} #{window_name}' 2>/dev/null)

  return 1
}

open_task_window() {
  local folder="$1"
  local tool="$2"
  shift 2
  local folder_path="$WORKTREES_DIR/$folder"
  local window_id=""
  local pane_id=""
  local tool_cmd=""

  tmux_enabled || return 0
  [[ -d "$folder_path" ]] || return 0

  if window_id="$(find_task_window "$folder")"; then
    tmux select-window -t "$window_id" 2>/dev/null || warn "could not select tmux window '$folder'"
    tmux switch-client -t "=$TASKS_SESSION" 2>/dev/null || true
    return 0
  fi

  if tmux has-session -t "=$TASKS_SESSION" 2>/dev/null; then
    if ! IFS=' ' read -r window_id pane_id < <(tmux new-window -t "=$TASKS_SESSION" -n "$folder" -c "$folder_path" -P -F '#{window_id} #{pane_id}' 2>/dev/null); then
      warn "could not create tmux window '$folder'"
      return 0
    fi
  else
    if ! IFS=' ' read -r window_id pane_id < <(tmux new-session -d -s "$TASKS_SESSION" -n "$folder" -c "$folder_path" -P -F '#{window_id} #{pane_id}' 2>/dev/null); then
      warn "could not create tmux session '$TASKS_SESSION'"
      return 0
    fi
  fi

  tmux split-window -h -t "$pane_id" -c "$folder_path" 2>/dev/null || warn "could not split tmux window '$folder'"
  tmux select-pane -t "$pane_id" 2>/dev/null || true

  printf -v tool_cmd '%q ' "$tool" "$@"
  tmux send-keys -t "$pane_id" "$tool_cmd" Enter 2>/dev/null || warn "could not start $tool in tmux window '$folder'"

  tmux select-window -t "$window_id" 2>/dev/null || true
  tmux switch-client -t "=$TASKS_SESSION" 2>/dev/null || true
}
```

Design notes (do not deviate):
- `${window_name#[*!]}` strips a single leading `*` or `!` status marker so a busy window still matches its task.
- The `=` prefix in `-t "=$TASKS_SESSION"` forces exact session-name matching (no prefix matches).
- When the tasks session does not exist, it is created directly WITH the task window (`new-session -n`), so no stray initial window appears.
- The tool is started via `send-keys` into the left pane's shell (not as the pane command) so the pane survives when the agent exits.
- All tmux failures are warnings, never fatal — worktree operations have already succeeded by the time these run. `switch-client` is `|| true` because a detached server has no client.

- [ ] **Step 3: Parse --no-tmux as a global first argument**

The dispatch currently starts at line 687 with:

```bash
if [[ $# -eq 0 ]]; then
  usage 0
fi

case "${1:-}" in
```

Insert between the `fi` and the `case`:

```bash
if [[ "${1:-}" == "--no-tmux" ]]; then
  IWORK_NO_TMUX=1
  shift
  if [[ $# -eq 0 ]]; then
    usage 1
  fi
fi
```

- [ ] **Step 4: Add the --switch-task-window internal flag**

In the same `case "${1:-}" in` block, after the `--resolve-park-target-path` entry (lines 722-725), add:

```bash
  --switch-task-window)
    tmux_enabled || exit 1
    validate_worktree_folder_name "${2:-}"
    switch_window_id="$(find_task_window "${2:-}")" || exit 1
    tmux select-window -t "$switch_window_id" 2>/dev/null || exit 1
    tmux switch-client -t "=$TASKS_SESSION" 2>/dev/null || true
    exit 0
    ;;
```

This exits 0 only if a task window existed and was selected — the shell wrapper (Task 4) uses the exit code to decide whether to fall back to a plain `cd`. `switch-client` is best-effort for the detached-server case.

- [ ] **Step 5: Syntax check**

Run: `bash -n /Users/sbk/dev/igloo/iwork/iwork && echo OK`
Expected: `OK`

- [ ] **Step 6: Verify --switch-task-window against the isolated tmux server**

Run the harness **Setup**, then:

```bash
# No tasks session yet -> exit 1
tmux -L iwork-test send-keys -t t:0 "'$IWORK' --switch-task-window test-task; echo RC=\$?" Enter
sleep 1
tmux -L iwork-test capture-pane -t t:0 -p | grep RC=
# Expected: RC=1

# Create the tasks session with a test-task window plus a dummy window so
# test-task is NOT the session's current window
tmux -L iwork-test new-session -d -s tasks -n test-task
tmux -L iwork-test new-window -t tasks -n dummy
tmux -L iwork-test send-keys -t t:0 "'$IWORK' --switch-task-window test-task; echo RC=\$?" Enter
sleep 1
tmux -L iwork-test capture-pane -t t:0 -p | grep RC= | tail -1
# Expected: RC=0
tmux -L iwork-test display-message -t tasks -p '#{window_name}'
# Expected: test-task   (the tasks session's current window changed)

# Marker stripping: rename to *test-task, select dummy, switch again
tmux -L iwork-test rename-window -t tasks:test-task '*test-task'
tmux -L iwork-test select-window -t tasks:dummy
tmux -L iwork-test send-keys -t t:0 "'$IWORK' --switch-task-window test-task; echo RC=\$?" Enter
sleep 1
tmux -L iwork-test display-message -t tasks -p '#{window_name}'
# Expected: *test-task
```

Run the harness **Teardown**.

- [ ] **Step 7: Commit**

```bash
git add iwork
git commit -m "feat: add tmux helpers, --no-tmux flag, and --switch-task-window"
```

### Task 2: tmux-aware claude/codex (run_tool_in_worktree)

**Files:**
- Modify: `iwork:147-156` (`run_tool_in_worktree`)

- [ ] **Step 1: Add the tmux branch to run_tool_in_worktree**

Replace:

```bash
run_tool_in_worktree() {
  local tool="$1"
  local folder="$2"
  local folder_path=""

  shift 2
  folder_path="$(resolve_worktree_folder "$folder")"
  cd "$folder_path"
  exec "$tool" "$@"
}
```

with:

```bash
run_tool_in_worktree() {
  local tool="$1"
  local folder="$2"
  local folder_path=""

  shift 2
  folder_path="$(resolve_worktree_folder "$folder")"

  if tmux_enabled; then
    open_task_window "$folder" "$tool" "$@"
    exit 0
  fi

  cd "$folder_path"
  exec "$tool" "$@"
}
```

- [ ] **Step 2: Syntax check**

Run: `bash -n /Users/sbk/dev/igloo/iwork/iwork && echo OK`
Expected: `OK`

- [ ] **Step 3: Verify window creation, no-duplicate, and --no-tmux**

Run the harness **Setup**, then:

```bash
# Creates the tasks session and the task window: claude left, shell right
tmux -L iwork-test send-keys -t t:0 "'$IWORK' claude test-task" Enter
sleep 1
tmux -L iwork-test list-windows -t tasks -F '#{window_name} #{window_panes}'
# Expected exactly one line: test-task 2   (no stray initial window)
tmux -L iwork-test capture-pane -t tasks:test-task.0 -p | grep CLAUDE-STARTED
# Expected: CLAUDE-STARTED
tmux -L iwork-test display-message -p -t tasks:test-task.0 '#{pane_current_path}'
# Expected: ends with /igloo/AAWORKTREES/test-task

# Re-run: selects the existing window, does NOT create a duplicate
tmux -L iwork-test send-keys -t t:0 "'$IWORK' claude test-task" Enter
sleep 1
tmux -L iwork-test list-windows -t tasks | grep -c test-task
# Expected: 1

# --no-tmux: runs claude in place (this execs in the test pane, so do it last)
tmux -L iwork-test send-keys -t t:0 "'$IWORK' --no-tmux claude test-task" Enter
sleep 1
tmux -L iwork-test capture-pane -t t:0 -p | grep CLAUDE-STARTED
# Expected: CLAUDE-STARTED
tmux -L iwork-test list-windows -t tasks | wc -l
# Expected: 1 (no new window)
```

Run the harness **Teardown**.

- [ ] **Step 4: Commit**

```bash
git add iwork
git commit -m "feat: open task window for claude/codex inside tmux"
```

### Task 3: open task window on creation and park

**Files:**
- Modify: `iwork:285-288` (end of `park_current_repo`), `iwork:783-794` (main creation path at end of script)

- [ ] **Step 1: Open the window after task creation**

The end of the script currently reads:

```bash
folder_name="${branch//\//-}"
branch_slug="$folder_name"

create_worktrees "$branch" "$folder_name" "$branch_slug" "${repos[@]}"
```

Add one line after `create_worktrees`:

```bash
create_worktrees "$branch" "$folder_name" "$branch_slug" "${repos[@]}"
open_task_window "$folder_name" claude
```

Note: do NOT add this to the `add-repo` dispatch — per spec, `add-repo` is unchanged.

- [ ] **Step 2: Open the window after park**

At the end of `park_current_repo` (currently lines 285-288):

```bash
  echo ""
  echo "Done! Worktree parked at:"
  echo "  $wt_path"
}
```

becomes:

```bash
  echo ""
  echo "Done! Worktree parked at:"
  echo "  $wt_path"

  open_task_window "$folder_name" claude
}
```

- [ ] **Step 3: Syntax check**

Run: `bash -n /Users/sbk/dev/igloo/iwork/iwork && echo OK`
Expected: `OK`

- [ ] **Step 4: Verify creation path**

Run the harness **Setup**, then:

```bash
tmux -L iwork-test send-keys -t t:0 "'$IWORK' feat/test-window -r repo-a" Enter
sleep 2
ls "$TD/igloo/AAWORKTREES/feat-test-window"
# Expected: repo-a--feat-test-window
tmux -L iwork-test list-windows -t tasks -F '#{window_name} #{window_panes}'
# Expected to include: feat-test-window 2
tmux -L iwork-test capture-pane -t tasks:feat-test-window.0 -p | grep CLAUDE-STARTED
# Expected: CLAUDE-STARTED
```

- [ ] **Step 5: Verify park path**

Continue in the same harness:

```bash
tmux -L iwork-test send-keys -t t:0 "cd '$TD/igloo/repo-a' && git switch -c feat/park-test && git commit -q --allow-empty -m wip && '$IWORK' park parked-task" Enter
sleep 2
ls "$TD/igloo/AAWORKTREES/parked-task"
# Expected: repo-a--feat-park-test
tmux -L iwork-test list-windows -t tasks -F '#{window_name}'
# Expected to include: parked-task
```

Run the harness **Teardown**.

- [ ] **Step 6: Commit**

```bash
git add iwork
git commit -m "feat: open task window on task creation and park"
```

### Task 4: tmux-aware shell integration (bash and zsh wrappers)

**Files:**
- Modify: `iwork` — the `iwork()` wrapper function inside BOTH `print_bash_completion` (heredoc, lines 443-487) and `print_zsh_completion` (heredoc, lines 556-600)

The two wrappers are nearly identical; apply the same replacement to both heredocs. The new wrapper body (replace the entire `iwork() { ... }` function inside each heredoc — bash version shown; the zsh heredoc currently uses `(( $# < 2 ))` arithmetic guards, replace it with this exact same text too, it is valid zsh):

- [ ] **Step 1: Replace the wrapper function in print_bash_completion's heredoc**

```bash
iwork() {
  local cmd=""
  local folder=""
  local target=""
  local notmux=""

  if [[ "${1:-}" == "--no-tmux" ]]; then
    notmux=1
    shift
  fi

  cmd="${1:-}"

  case "$cmd" in
    park)
      if [[ $# -lt 2 ]]; then
        command "$_iwork_bin" park
        return $?
      fi

      folder="$2"
      target="$(command "$_iwork_bin" --resolve-park-target-path "$folder")" || return $?
      command "$_iwork_bin" ${notmux:+--no-tmux} park "$folder" || return $?
      if [[ -z "${TMUX:-}" || -n "$notmux" ]]; then
        builtin cd "$target" || return $?
      fi
      ;;
    cd)
      if [[ $# -lt 2 ]]; then
        command "$_iwork_bin" cd
        return $?
      fi

      folder="$2"
      shift 2
      if [[ -n "${TMUX:-}" && -z "$notmux" ]] && command "$_iwork_bin" --switch-task-window "$folder" 2>/dev/null; then
        return 0
      fi
      target="$(command "$_iwork_bin" --resolve-worktree-folder "$folder")" || return $?
      builtin cd "$target" || return $?
      ;;
    claude|codex)
      if [[ $# -lt 2 ]]; then
        command "$_iwork_bin" "$cmd"
        return $?
      fi

      folder="$2"
      shift 2
      if [[ -n "${TMUX:-}" && -z "$notmux" ]]; then
        command "$_iwork_bin" "$cmd" "$folder" "$@"
        return $?
      fi
      target="$(command "$_iwork_bin" --resolve-worktree-folder "$folder")" || return $?
      builtin cd "$target" || return $?
      "$cmd" "$@"
      ;;
    *)
      command "$_iwork_bin" ${notmux:+--no-tmux} "$@"
      ;;
  esac
}
```

Behavior summary:
- `cd`: in tmux, switch to the task window if one exists (exit 0 from `--switch-task-window`); otherwise plain cd of the current pane. `--no-tmux` forces plain cd.
- `claude`/`codex`: in tmux, delegate to the binary (which opens/switches the task window in the tasks session); outside tmux, keep today's cd-and-run-in-this-shell behavior.
- `park`: the binary opens the window itself when in tmux, so the wrapper only cds when no window was opened.
- default (branch creation etc.): pass `--no-tmux` through.

- [ ] **Step 2: Apply the identical replacement to the wrapper in print_zsh_completion's heredoc**

Same function text as Step 1. (In zsh, unquoted `${notmux:+--no-tmux}` expands to one word when set and disappears when empty — the same net effect as bash here.)

- [ ] **Step 3: Syntax check both generated outputs**

```bash
bash -n /Users/sbk/dev/igloo/iwork/iwork && echo OK
/Users/sbk/dev/igloo/iwork/iwork --completion bash > /tmp/iwork-completion.bash && bash -n /tmp/iwork-completion.bash && echo BASH-OK
/Users/sbk/dev/igloo/iwork/iwork --completion zsh > /tmp/iwork-completion.zsh && zsh -n /tmp/iwork-completion.zsh && echo ZSH-OK
```

Expected: `OK`, `BASH-OK`, `ZSH-OK`

- [ ] **Step 4: Verify the zsh wrapper interactively**

Run the harness **Setup**, then:

```bash
tmux -L iwork-test send-keys -t t:0 "source <('$IWORK' --completion zsh)" Enter

# Create a task window via the wrapper
tmux -L iwork-test send-keys -t t:0 "iwork claude test-task" Enter
sleep 1
tmux -L iwork-test list-windows -t tasks -F '#{window_name}'
# Expected: test-task

# iwork cd selects the existing task window (and would switch an attached client)
tmux -L iwork-test new-window -t tasks -n dummy
tmux -L iwork-test send-keys -t t:0 "iwork cd test-task; echo RC=\$?" Enter
sleep 1
tmux -L iwork-test capture-pane -t t:0 -p | grep RC= | tail -1
# Expected: RC=0
tmux -L iwork-test display-message -t tasks -p '#{window_name}'
# Expected: test-task

# Kill the tasks session; iwork cd now falls back to a plain cd in the current pane
tmux -L iwork-test kill-session -t tasks
tmux -L iwork-test send-keys -t t:0 "iwork cd test-task && pwd" Enter
sleep 1
tmux -L iwork-test capture-pane -t t:0 -p | tail -3
# Expected: pwd output ending in /igloo/AAWORKTREES/test-task

# --no-tmux cd is a plain cd even when a task window exists
tmux -L iwork-test send-keys -t t:0 "cd / && iwork claude test-task" Enter
sleep 1
tmux -L iwork-test send-keys -t t:0 "iwork --no-tmux cd test-task && pwd" Enter
sleep 1
tmux -L iwork-test capture-pane -t t:0 -p | tail -3
# Expected: pwd output ending in /igloo/AAWORKTREES/test-task
```

Run the harness **Teardown**.

- [ ] **Step 5: Commit**

```bash
git add iwork
git commit -m "feat: tmux-aware shell integration for cd, claude, codex, and park"
```

### Task 5: --hook handler for agent status markers

**Files:**
- Modify: `iwork` — new function after `open_task_window`; new dispatch entry after `--switch-task-window`

- [ ] **Step 1: Add the hook handler function**

Insert after `open_task_window`:

```bash
handle_claude_hook() {
  local input=""
  local event=""
  local window_name=""
  local base=""
  local marker=""

  [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]] || exit 0

  input="$(cat 2>/dev/null || true)"
  event="$(printf '%s' "$input" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
  [[ -n "$event" ]] || exit 0

  window_name="$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null)" || exit 0
  base="${window_name#[*!]}"
  [[ -n "$base" && -d "$WORKTREES_DIR/$base" ]] || exit 0

  case "$event" in
    UserPromptSubmit)
      marker='*'
      ;;
    Stop|Notification)
      marker='!'
      ;;
    *)
      exit 0
      ;;
  esac

  if [[ "$window_name" != "${marker}${base}" ]]; then
    tmux rename-window -t "$TMUX_PANE" "${marker}${base}" 2>/dev/null || true
  fi

  exit 0
}
```

Every line is guarded: this function must exit 0 no matter what (missing tmux, malformed JSON, unknown event, rename failure). The `-d "$WORKTREES_DIR/$base"` check is what protects repo-named windows from ever being renamed by ad-hoc claude runs. Renaming via `$TMUX_PANE` works regardless of which session the window is in.

- [ ] **Step 2: Add the dispatch entry**

In the `case "${1:-}" in` dispatch block, after the `--switch-task-window` entry, add:

```bash
  --hook)
    handle_claude_hook
    ;;
```

- [ ] **Step 3: Syntax check**

Run: `bash -n /Users/sbk/dev/igloo/iwork/iwork && echo OK`
Expected: `OK`

- [ ] **Step 4: Verify renames and the repo-window guard**

Run the harness **Setup**, then create a task window and grab tmux identifiers (this technique calls `--hook` from outside the test pane while faking the env the real hook would have — `$TMUX` for socket routing and `$TMUX_PANE` for window targeting):

```bash
tmux -L iwork-test send-keys -t t:0 "'$IWORK' claude test-task" Enter
sleep 1
WID=$(tmux -L iwork-test list-windows -t tasks -F '#{window_id} #{window_name}' | awk '$2=="test-task"{print $1}')
PANE=$(tmux -L iwork-test list-panes -t "$WID" -F '#{pane_id}' | head -1)
SOCK=$(tmux -L iwork-test display-message -p '#{socket_path}')

# Stop -> !test-task
echo '{"hook_event_name":"Stop"}' | TMUX="$SOCK,0,0" TMUX_PANE="$PANE" IGLOO_DIR="$TD/igloo" "$IWORK" --hook; echo "RC=$?"
# Expected: RC=0
tmux -L iwork-test list-windows -t tasks -F '#{window_name}' | grep test-task
# Expected: !test-task

# UserPromptSubmit -> *test-task
echo '{"hook_event_name":"UserPromptSubmit"}' | TMUX="$SOCK,0,0" TMUX_PANE="$PANE" IGLOO_DIR="$TD/igloo" "$IWORK" --hook
tmux -L iwork-test list-windows -t tasks -F '#{window_name}' | grep test-task
# Expected: *test-task

# Notification -> !test-task
echo '{"hook_event_name":"Notification"}' | TMUX="$SOCK,0,0" TMUX_PANE="$PANE" IGLOO_DIR="$TD/igloo" "$IWORK" --hook
tmux -L iwork-test list-windows -t tasks -F '#{window_name}' | grep test-task
# Expected: !test-task

# Repo-named window is never renamed
tmux -L iwork-test rename-window -t t:0 repo-a
PANE0=$(tmux -L iwork-test list-panes -t t:0 -F '#{pane_id}' | head -1)
echo '{"hook_event_name":"Stop"}' | TMUX="$SOCK,0,0" TMUX_PANE="$PANE0" IGLOO_DIR="$TD/igloo" "$IWORK" --hook; echo "RC=$?"
# Expected: RC=0
tmux -L iwork-test display-message -p -t t:0 '#{window_name}'
# Expected: repo-a (unchanged)

# Garbage input exits 0 silently
echo 'not json' | TMUX="$SOCK,0,0" TMUX_PANE="$PANE" IGLOO_DIR="$TD/igloo" "$IWORK" --hook; echo "RC=$?"
# Expected: RC=0, no output

# Outside tmux exits 0 silently
echo '{"hook_event_name":"Stop"}' | env -u TMUX -u TMUX_PANE "$IWORK" --hook; echo "RC=$?"
# Expected: RC=0, no output
```

Run the harness **Teardown**.

- [ ] **Step 5: Commit**

```bash
git add iwork
git commit -m "feat: add --hook handler for agent status window markers"
```

### Task 6: install-hooks subcommand

**Files:**
- Modify: `iwork` — new function after `handle_claude_hook`; new dispatch block after the `park` dispatch (~line 740)

- [ ] **Step 1: Add the install function**

Insert after `handle_claude_hook`:

```bash
install_claude_hooks() {
  local settings_path="$1"
  local hook_cmd="$SELF_PATH --hook"

  command -v python3 >/dev/null 2>&1 || die "install-hooks requires python3"

  python3 - "$settings_path" "$hook_cmd" <<'PY'
import json
import os
import sys

settings_path = sys.argv[1]
cmd = sys.argv[2]
events = ["UserPromptSubmit", "Stop", "Notification"]

data = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        data = json.load(f)

hooks = data.setdefault("hooks", {})
to_add = []
for ev in events:
    entries = hooks.setdefault(ev, [])
    present = any(
        h.get("command") == cmd
        for entry in entries
        for h in entry.get("hooks", [])
    )
    if not present:
        to_add.append(ev)

if not to_add:
    print(f"iwork hook already installed for all events in {settings_path}")
    sys.exit(0)

print(f"Will add to {settings_path}:")
for ev in to_add:
    print(f'  {ev}: {{"type": "command", "command": "{cmd}"}}')

if os.environ.get("IWORK_ASSUME_YES") != "1":
    try:
        with open("/dev/tty") as tty:
            print("Proceed? [y/N] ", end="", flush=True)
            answer = tty.readline().strip().lower()
    except OSError:
        sys.exit("no TTY available for confirmation; aborting")
    if answer != "y":
        sys.exit("aborted")

for ev in to_add:
    hooks[ev].append({"hooks": [{"type": "command", "command": cmd}]})

settings_dir = os.path.dirname(settings_path)
if settings_dir:
    os.makedirs(settings_dir, exist_ok=True)
tmp_path = settings_path + ".tmp"
with open(tmp_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp_path, settings_path)
print(f"Updated {settings_path}")
PY
}
```

Notes:
- The hook command embeds `$SELF_PATH` (the absolute script path), so it works regardless of PATH when Claude Code runs it.
- Idempotent: events that already contain the exact command are skipped; re-running prints "already installed".
- Shows what it will add and confirms via `/dev/tty` before writing. `IWORK_ASSUME_YES=1` skips the prompt (for non-interactive use and testing).
- Writes via temp file + `os.replace` so a crash can't truncate settings.json.

- [ ] **Step 2: Add the dispatch block**

After the `park` dispatch block (ends `exit 0` / `fi` around line 740), add:

```bash
if [[ "${1:-}" == "install-hooks" ]]; then
  if [[ $# -gt 2 ]]; then
    die "usage: iwork install-hooks [settings-path]"
  fi

  install_claude_hooks "${2:-$HOME/.claude/settings.json}"
  exit 0
fi
```

The optional path argument exists for testing; the default is the real `~/.claude/settings.json`.

- [ ] **Step 3: Syntax check**

Run: `bash -n /Users/sbk/dev/igloo/iwork/iwork && echo OK`
Expected: `OK`

- [ ] **Step 4: Verify against a temp settings file (NOT the real one)**

```bash
IWORK=/Users/sbk/dev/igloo/iwork/iwork
TD="$(mktemp -d)"

# Fresh install into a file that already has unrelated settings
printf '{"model": "opus"}\n' > "$TD/settings.json"
IWORK_ASSUME_YES=1 "$IWORK" install-hooks "$TD/settings.json"
# Expected output: "Will add to ..." for UserPromptSubmit, Stop, Notification, then "Updated ..."
python3 -m json.tool "$TD/settings.json"
# Expected: valid JSON; "model": "opus" preserved; hooks.UserPromptSubmit/Stop/Notification each
# contain {"hooks": [{"type": "command", "command": "/Users/sbk/dev/igloo/iwork/iwork --hook"}]}
grep -c -- '--hook' "$TD/settings.json"
# Expected: 3

# Idempotent re-run
IWORK_ASSUME_YES=1 "$IWORK" install-hooks "$TD/settings.json"
# Expected: "iwork hook already installed for all events in ..."
grep -c -- '--hook' "$TD/settings.json"
# Expected: still 3

# Missing file is created
IWORK_ASSUME_YES=1 "$IWORK" install-hooks "$TD/nested/settings.json"
python3 -m json.tool "$TD/nested/settings.json" > /dev/null && echo VALID
# Expected: VALID

rm -rf "$TD"
```

- [ ] **Step 5: Commit**

```bash
git add iwork
git commit -m "feat: add install-hooks subcommand for Claude Code status hooks"
```

### Task 7: list status column

**Files:**
- Modify: `iwork` — new function after `list_worktree_folders` (line 133); modify the `list` dispatch (lines 728-731)

- [ ] **Step 1: Add list_worktree_folders_with_status**

Insert after the closing `}` of `list_worktree_folders` (line 133):

```bash
list_worktree_folders_with_status() {
  local folders=""
  local windows=""
  local folder=""
  local window_name=""
  local status=""
  local width=0

  folders="$(list_worktree_folders)"
  [[ -n "$folders" ]] || return 0

  windows="$(tmux list-windows -t "=$TASKS_SESSION" -F '#{window_name}' 2>/dev/null || true)"

  while IFS= read -r folder; do
    if (( ${#folder} > width )); then
      width=${#folder}
    fi
  done <<< "$folders"

  while IFS= read -r folder; do
    status=""
    while IFS= read -r window_name; do
      [[ -n "$window_name" ]] || continue
      case "$window_name" in
        '*'"$folder")
          status='*running'
          break
          ;;
        '!'"$folder")
          status='!waiting'
          break
          ;;
        "$folder")
          status='open'
          break
          ;;
      esac
    done <<< "$windows"

    if [[ -n "$status" ]]; then
      printf '%-*s  %s\n' "$width" "$folder" "$status"
    else
      printf '%s\n' "$folder"
    fi
  done <<< "$folders"
}
```

Note: this references the `TASKS_SESSION` global (defined in Task 1 near the top of the script), and only the dispatch (which runs after all function definitions) calls it.

- [ ] **Step 2: Make the list dispatch tmux-aware**

Replace (lines 728-731):

```bash
if [[ "${1:-}" == "list" && $# -eq 1 ]]; then
  list_worktree_folders
  exit 0
fi
```

with:

```bash
if [[ "${1:-}" == "list" && $# -eq 1 ]]; then
  if tmux_enabled; then
    list_worktree_folders_with_status
  else
    list_worktree_folders
  fi
  exit 0
fi
```

(`iwork --no-tmux list` therefore gives the plain, script-friendly output even inside tmux.)

- [ ] **Step 3: Syntax check**

Run: `bash -n /Users/sbk/dev/igloo/iwork/iwork && echo OK`
Expected: `OK`

- [ ] **Step 4: Verify**

Run the harness **Setup**, then:

```bash
# Outside tmux: plain output (run directly, not via send-keys)
IGLOO_DIR="$TD/igloo" "$IWORK" list
# Expected exactly:
# other-task
# test-task

# Inside tmux: status column reads the tasks session
tmux -L iwork-test new-session -d -s tasks -n '*test-task'
tmux -L iwork-test send-keys -t t:0 "'$IWORK' list" Enter
sleep 1
tmux -L iwork-test capture-pane -t t:0 -p | tail -4
# Expected to include:
# other-task
# test-task   *running

# Marker variants
tmux -L iwork-test rename-window -t tasks:'*test-task' '!test-task'
tmux -L iwork-test send-keys -t t:0 "'$IWORK' list" Enter
sleep 1
tmux -L iwork-test capture-pane -t t:0 -p | tail -4
# Expected to include: test-task   !waiting

tmux -L iwork-test rename-window -t tasks:'!test-task' 'test-task'
tmux -L iwork-test send-keys -t t:0 "'$IWORK' list" Enter
sleep 1
tmux -L iwork-test capture-pane -t t:0 -p | tail -4
# Expected to include: test-task   open

# --no-tmux inside tmux: plain output
tmux -L iwork-test send-keys -t t:0 "'$IWORK' --no-tmux list" Enter
sleep 1
tmux -L iwork-test capture-pane -t t:0 -p | tail -3
# Expected: other-task / test-task with no status column
```

Run the harness **Teardown**.

- [ ] **Step 5: Commit**

```bash
git add iwork
git commit -m "feat: show task window status in list output"
```

### Task 8: usage text and completions

**Files:**
- Modify: `iwork:8-50` (usage), `iwork:531` and `iwork:536` (bash completion word lists), `iwork:609-617` (zsh `_values` command list)

- [ ] **Step 1: Update usage()**

Replace the usage heredoc body (lines 10-47) with:

```
Usage: iwork [--no-tmux] <branch-name> -r <repo1> [repo2 ...]
       iwork add-repo <folder-name-in-AAWORKTREES> -r <repo1> [repo2 ...]
       iwork [--no-tmux] park <folder-name-in-AAWORKTREES>
       iwork [--no-tmux] list
       iwork [--no-tmux] cd <folder-name-in-AAWORKTREES>
       iwork [--no-tmux] claude <folder-name-in-AAWORKTREES> [claude-args...]
       iwork [--no-tmux] codex <folder-name-in-AAWORKTREES> [codex-args...]
       iwork install-hooks [settings-path]
       iwork --completion <bash|zsh>

Create a worktree folder in AAWORKTREES and set up git worktrees for the
specified repos, all on the given branch.

Inside tmux, each task maps to a window in a dedicated 'tasks' session
(override the name with IWORK_TMUX_SESSION). Creation and park open the
window (claude starts in the left pane, a shell in the right);
claude/codex/cd switch to it if it exists. Claude Code hooks (see
install-hooks) mark the window name with the agent state:
*task = busy, !task = waiting for you.

Subcommands:
  add-repo       Add one or more repos to an existing worktree folder
  park           Move the current repo/branch into a worktree folder
  list           List folders under AAWORKTREES (with window status in tmux)
  cd             Switch to the task window, or cd into the worktree folder
                 Requires sourced shell integration from --completion
  claude         Open/switch to the task window and run claude there
  codex          Open/switch to the task window and run codex there
  install-hooks  Add Claude Code hooks to ~/.claude/settings.json that keep
                 tmux window names in sync with agent status

Examples:
  iwork feat/bla -r rent-api accounting-api
  iwork fix/login-bug -r auth-api rent-frontend-v2
  iwork add-repo feat-contract-status-improvements -r auth-api
  iwork park task-billing-followup
  iwork list
  iwork cd feat-contract-status-improvements
  iwork claude feat-contract-status-improvements
  iwork --no-tmux claude feat-contract-status-improvements
  iwork install-hooks

Options:
  --no-tmux  Skip all tmux window handling (must be the first argument)
  -r         Repos to create worktrees for (required, at least one)
  -h         Show this help

Completion:
  source <(iwork --completion bash)
  source <(iwork --completion zsh)
```

- [ ] **Step 2: Update the bash completion word lists**

Line 531:

```bash
    COMPREPLY=( $(compgen -W "add-repo park list cd claude codex -h --help --completion" -- "$cur") )
```

becomes:

```bash
    COMPREPLY=( $(compgen -W "add-repo park list cd claude codex install-hooks --no-tmux -h --help --completion" -- "$cur") )
```

Line 536:

```bash
    COMPREPLY=( $(compgen -W "-r -h --help --completion" -- "$cur") )
```

becomes:

```bash
    COMPREPLY=( $(compgen -W "-r -h --help --completion --no-tmux" -- "$cur") )
```

- [ ] **Step 3: Update the zsh completion command list**

In `print_zsh_completion`'s `_iwork` function, the `_values 'command' \` block (lines 609-616) becomes:

```bash
    _values 'command' \
      'add-repo[add repos to an existing worktree folder]' \
      'park[move the current repo branch into a worktree folder]' \
      'list[list worktree folders]' \
      'cd[cd into a worktree folder or switch to its tmux window]' \
      'claude[open the task tmux window and run claude]' \
      'codex[open the task tmux window and run codex]' \
      'install-hooks[install Claude Code status hooks]' \
      '--no-tmux[skip tmux window handling]' \
      '--completion[print shell integration]'
```

- [ ] **Step 4: Syntax check and eyeball the help**

```bash
bash -n /Users/sbk/dev/igloo/iwork/iwork && echo OK
/Users/sbk/dev/igloo/iwork/iwork --help
/Users/sbk/dev/igloo/iwork/iwork --completion bash > /tmp/c.bash && bash -n /tmp/c.bash && echo BASH-OK
/Users/sbk/dev/igloo/iwork/iwork --completion zsh > /tmp/c.zsh && zsh -n /tmp/c.zsh && echo ZSH-OK
```

Expected: `OK`, full help text, `BASH-OK`, `ZSH-OK`.

- [ ] **Step 5: Commit**

```bash
git add iwork
git commit -m "docs: update usage and completions for tmux task windows"
```

### Task 9: Real-environment setup and smoke test (with the user)

This is a checklist for the user's actual environment, not the isolated harness. Do these together with the user or hand them the list:

- [ ] **Step 1: Re-source shell integration** — `source <(iwork --completion zsh)` (or restart the shell).
- [ ] **Step 2: Install hooks for real** — `iwork install-hooks`, review the printed additions, confirm. Then check `~/.claude/settings.json` looks sane.
- [ ] **Step 3: Apply the tmux.conf additions** — with the user's go-ahead, update `~/.tmux.conf`: add the session-switching binds and replace the `status-right` line with the waiting-counter variant, then `tmux source-file ~/.tmux.conf`:

```tmux
# prefix+Tab: toggle between current and last session (igloo <-> tasks flip)
bind Tab switch-client -l
# prefix+T / prefix+I: jump straight to a session
bind T switch-client -t tasks
bind I switch-client -t igloo
```

And replace `set -g status-right '%Y-%m-%d %H:%M:%S'` with:

```tmux
set -g status-right '!#(tmux list-windows -t tasks -F "#W" 2>/dev/null | grep -c "^!")  %Y-%m-%d %H:%M:%S'
```

- [ ] **Step 4: Create a real throwaway task** — from the igloo session: `iwork test/iwork-tmux -r email-templates`. Expect: worktree created, a `tasks` session appears with window `test-iwork-tmux` (claude starting left, shell right), and the client switches to it.
- [ ] **Step 5: Talk to claude in the task window** — after submitting a prompt the window should show `*test-iwork-tmux`; when claude finishes, `!test-iwork-tmux`, and the `!` counter in status-right should read `!1` from the igloo session.
- [ ] **Step 6: Session switching** — `prefix+Tab` flips between igloo and tasks; `prefix+T`/`prefix+I` jump directly; `prefix+w` shows both sessions with markers.
- [ ] **Step 7: Sanity-check repo windows** — run `claude` ad hoc in a repo window (e.g. `auth-api`), submit a prompt, confirm the window name does NOT change.
- [ ] **Step 8: `iwork list`** — shows the status column for the test task.
- [ ] **Step 9: Clean up** — exit claude, kill the test window, remove the worktrees: `git -C ~/dev/igloo/email-templates worktree remove ~/dev/igloo/AAWORKTREES/test-iwork-tmux/email-templates--test-iwork-tmux && git -C ~/dev/igloo/email-templates branch -D test/iwork-tmux && rmdir ~/dev/igloo/AAWORKTREES/test-iwork-tmux`.
