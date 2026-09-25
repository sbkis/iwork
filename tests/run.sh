#!/usr/bin/env bash
# Sandboxed test suite for iwork.
#
# Every test runs against a throwaway tree under $TMPDIR: fake repos, fake
# tasks dir, fake projects dir, fake HOME, and a tmux server on its own socket.
# Nothing here can see or touch the real IWORK_REPO_DIR, the real ~/.config, or
# a live tmux session. The guards in assert_sandboxed enforce that.
#
#   tests/run.sh            run everything
#   tests/run.sh todo       run tests whose name matches 'todo'
#   KEEP=1 tests/run.sh     leave the sandbox behind for inspection

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWORK_SRC="$(cd "$TESTS_DIR/.." && pwd)/iwork"
FILTER="${1:-}"

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
SB=""
PASS=0
FAIL=0
CURRENT=""
FAILED_TESTS=()

[[ -x "$IWORK_SRC" ]] || { echo "fatal: no executable iwork at $IWORK_SRC" >&2; exit 1; }

# The whole safety story: refuse to run unless every path we are about to write
# to is inside a sandbox under $TMPDIR. A copy-paste accident that pointed these
# at the real tree would otherwise create and delete real worktrees.
assert_sandboxed() {
  case "$SB" in
    "$TMP_BASE"/iwork-test.*) ;;
    *) echo "fatal: sandbox '$SB' is not under $TMP_BASE" >&2; exit 1 ;;
  esac
  local dir=""
  for dir in "$SB_REPOS" "$SB_TASKS" "$SB_PROJECTS" "$SB_HOME"; do
    case "$dir" in
      "$SB"/*) ;;
      *) echo "fatal: '$dir' escapes the sandbox" >&2; exit 1 ;;
    esac
  done
}

setup_sandbox() {
  SB="$(mktemp -d "$TMP_BASE/iwork-test.XXXXXX")" || exit 1
  SB_REPOS="$SB/repos"
  SB_TASKS="$SB/tasks"
  SB_PROJECTS="$SB/projects"
  SB_HOME="$SB/home"
  SB_ORIGINS="$SB/origins"
  assert_sandboxed

  mkdir -p "$SB_REPOS" "$SB_TASKS" "$SB_PROJECTS" "$SB_HOME/.config/iwork" \
           "$SB_ORIGINS" "$SB/tmux"

  cat > "$SB/config" <<CONF
IWORK_REPO_DIR="$SB_REPOS"
IWORK_TASKS_DIR="$SB_TASKS"
IWORK_PROJECTS_DIR="$SB_PROJECTS"
CONF

  # iwork send-keys a real 'claude' (and 'nvim' under --big) into the panes it
  # creates. A test suite must not launch an actual agent or editor, and a
  # long-lived one would also hold the suite's stdout open.
  mkdir -p "$SB/bin"
  local stub=""
  for stub in claude codex nvim; do
    printf '#!/bin/sh\nexit 0\n' > "$SB/bin/$stub"
    chmod +x "$SB/bin/$stub"
  done

  # Start the tmux server here, with its file descriptors detached. Whichever
  # command first needs a server would otherwise spawn a daemon holding this
  # suite's stdout, so anything reading our output (a pipe to tail, a CI
  # collector) would block until teardown even though the run had finished.
  if command -v tmux >/dev/null 2>&1; then
    env -u TMUX TMUX_TMPDIR="$SB/tmux" tmux -f /dev/null start-server \
      </dev/null >/dev/null 2>&1 || true
  fi

  cat > "$SB_HOME/.gitconfig" <<CONF
[user]
	name = iwork tests
	email = tests@example.invalid
[init]
	defaultBranch = main
[commit]
	gpgsign = false
CONF
}

teardown_sandbox() {
  [[ -n "${KEEP:-}" ]] && { echo "sandbox kept: $SB"; return 0; }
  [[ -n "$SB" ]] || return 0
  assert_sandboxed
  tmux_kill_server
  chmod -R u+w "$SB" 2>/dev/null
  rm -rf "$SB"
}

mk_repo() {
  local name="$1"
  local repo="$SB_REPOS/$name"
  local origin="$SB_ORIGINS/$name.git"

  git init -q -b main "$repo"
  echo "# $name" > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "initial"
  git init -q --bare "$origin"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q -u origin main
}

# Every iwork invocation goes through here, so no test can accidentally reach
# the real config or the real tmux server.
iw() {
  local env_args=()
  local no_tmux="1"

  # WANT_TMUX=1 lets a test drive the real tmux paths against the sandbox's own
  # tmux server. This used to read "${WANT_TMUX:+}${WANT_TMUX:-1}", which
  # evaluates to 1 whether WANT_TMUX is set or not — so the hatch was dead and
  # no test ever exercised window creation.
  [[ -n "${WANT_TMUX:-}" ]] && no_tmux=""

  env_args=(
    PATH="$SB/bin:$PATH"
    IWORK_EDITOR="nvim"
    HOME="$SB_HOME"
    GIT_CONFIG_GLOBAL="$SB_HOME/.gitconfig"
    TMUX_TMPDIR="$SB/tmux"
    IWORK_CONFIG_FILE="$SB/config"
    IWORK_REPO_DIR="$SB_REPOS"
    IWORK_TASKS_DIR="$SB_TASKS"
    IWORK_PROJECTS_DIR="$SB_PROJECTS"
    IWORK_CONTEXT_TEMPLATE="$SB_HOME/.config/iwork/task-context.md.tmpl"
    IWORK_PROJECT_TEMPLATE="$SB_HOME/.config/iwork/project-context.md.tmpl"
    IWORK_NO_TMUX="$no_tmux"
    IWORK_ASSUME_YES="${ASSUME_YES-1}"
    # Always set, never inherited. A suite run from inside a real Claude session
    # would otherwise register that session into the sandbox's projects, and the
    # agent tests would assert against whoever happened to be running them.
    CLAUDE_CODE_SESSION_ID="${WANT_SESSION_ID:-}"
    CLAUDE_PID="${WANT_CLAUDE_PID:-}"
    TMUX_PANE="${WANT_PANE:-}"
  )

  # Only forwarded when a test sets them, so iwork sees its own defaults
  # otherwise.
  [[ -n "${WANT_ENTRY_MAX:-}" ]] && env_args+=(IWORK_ENTRY_MAX_CHARS="$WANT_ENTRY_MAX")
  [[ -n "${WANT_SHOW_LINES+x}" ]] && env_args+=(IWORK_SHOW_LOG_LINES="$WANT_SHOW_LINES")
  [[ -n "${WANT_PROJECT_ENV:-}" ]] && env_args+=(IWORK_PROJECT="$WANT_PROJECT_ENV")
  [[ -n "${WANT_SESSION_MARKERS:-}" ]] && env_args+=(IWORK_SESSION_MARKERS="$WANT_SESSION_MARKERS")

  env -u TMUX "${env_args[@]}" "$IWORK_SRC" "$@"
}

# Same, but from inside a task directory, which is how agents will call it.
iw_in() {
  local dir="$1"
  shift
  ( cd "$dir" && iw "$@" )
}

tmux_t() { env -u TMUX TMUX_TMPDIR="$SB/tmux" tmux -f /dev/null "$@"; }

# send-keys returns once the keys are in the pane's input buffer, not once the
# command has started, so a test that reads pane state straight afterwards races
# the shell and sees the shell.
# A session's live name carries whatever marker its windows currently justify,
# and folding two of them re-derives it -- so tests look sessions up by base.
windows_of_session() {
  local base="$1" name="" live=""

  while IFS= read -r name; do
    if [[ "${name#[*!]}" == "$base" ]]; then live="$name"; break; fi
  done < <(tmux_t list-sessions -F '#{session_name}' 2>/dev/null)

  [[ -n "$live" ]] || return 0
  tmux_t list-windows -t "=$live" -F '#{window_name}' 2>/dev/null | tr '\n' ' '
}

wait_for_pane_command() {
  local pane="$1" want="$2" waited=0

  while (( waited < 50 )); do
    [[ "$(tmux_t display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)" != "$want" ]] || return 0
    command sleep 0.1
    waited=$((waited + 1))
  done

  return 1
}
tmux_kill_server() { env -u TMUX TMUX_TMPDIR="$SB/tmux" tmux kill-server 2>/dev/null; return 0; }

# --- assertions ---------------------------------------------------------------

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$CURRENT: $1"); printf '    FAIL %s\n' "$1"; }

assert_ok() {
  local msg="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok; else bad "$msg (command failed: $*)"; fi
}

assert_fails() {
  local msg="$1"
  shift
  if "$@" >/dev/null 2>&1; then bad "$msg (command unexpectedly succeeded: $*)"; else ok; fi
}

assert_eq() {
  local msg="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then ok; else bad "$msg (want '$want', got '$got')"; fi
}

assert_file() {
  local msg="$1" path="$2"
  if [[ -f "$path" ]]; then ok; else bad "$msg (no file: $path)"; fi
}

assert_no_file() {
  local msg="$1" path="$2"
  if [[ ! -e "$path" ]]; then ok; else bad "$msg (exists: $path)"; fi
}

assert_dir() {
  local msg="$1" path="$2"
  if [[ -d "$path" ]]; then ok; else bad "$msg (no dir: $path)"; fi
}

assert_link() {
  local msg="$1" path="$2"
  if [[ -L "$path" ]]; then ok; else bad "$msg (not a symlink: $path)"; fi
}

assert_grep() {
  local msg="$1" pattern="$2" path="$3"
  if grep -q -- "$pattern" "$path" 2>/dev/null; then ok
  else bad "$msg (no match for '$pattern' in $path)"; fi
}

assert_no_grep() {
  local msg="$1" pattern="$2" path="$3"
  if grep -q -- "$pattern" "$path" 2>/dev/null; then bad "$msg (unexpected match for '$pattern' in $path)"
  else ok; fi
}

assert_no_grep_str() {
  local msg="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) bad "$msg (output unexpectedly contained '$needle')" ;;
    *) ok ;;
  esac
}

assert_contains() {
  local msg="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) ok ;;
    *) bad "$msg (output did not contain '$needle')" ;;
  esac
}

run_test() {
  local name="$1"
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && return 0
  CURRENT="$name"
  printf '  %s\n' "$name"
  printf '%s' "$name" > "$STATE_FILE"
  setup_sandbox
  "$name"
  teardown_sandbox
  SB=""
}

# A hung suite must say which test hung. confirm() in iwork reads /dev/tty, so a
# test that forgets -f or IWORK_ASSUME_YES would otherwise block forever with no
# indication of where. The whole suite runs in well under a minute.
SUITE_TIMEOUT="${SUITE_TIMEOUT:-300}"
STATE_FILE="$(mktemp "$TMP_BASE/iwork-test-state.XXXXXX")"

# Polls in one-second steps rather than sleeping through the whole timeout: a
# background sleep inherits stdout, so it would hold the pipe open long after the
# suite exited and anything reading it (tail, a CI collector) would appear to
# hang. Deleting STATE_FILE is the shutdown signal.
start_watchdog() {
  (
    waited=0
    while (( waited < SUITE_TIMEOUT )); do
      [[ -f "$STATE_FILE" ]] || exit 0
      command sleep 1
      waited=$((waited + 1))
    done
    printf '\nTIMED OUT after %ss while running: %s\n' \
      "$SUITE_TIMEOUT" "$(cat "$STATE_FILE" 2>/dev/null)" >&2
    kill -9 "$$" 2>/dev/null
  ) &
  WATCHDOG_PID=$!
  # bash 3.2 announces the killed job by echoing its whole body; disowning it
  # keeps that out of the test output.
  disown "$WATCHDOG_PID" 2>/dev/null || true
}

stop_watchdog() {
  rm -f "$STATE_FILE" 2>/dev/null
  [[ -n "${WATCHDOG_PID:-}" ]] && kill "$WATCHDOG_PID" 2>/dev/null
  return 0
}

# --- baseline: existing behaviour must not regress ----------------------------

test_baseline_task_creation() {
  mk_repo backend
  mk_repo frontend
  iw feat/thing -r backend frontend >/dev/null 2>&1

  assert_dir "task folder created" "$SB_TASKS/feat-thing"
  assert_dir "backend worktree" "$SB_TASKS/feat-thing/backend"
  assert_dir "frontend worktree" "$SB_TASKS/feat-thing/frontend"
  assert_file "CLAUDE.md written" "$SB_TASKS/feat-thing/CLAUDE.md"
  assert_file "AGENTS.md written" "$SB_TASKS/feat-thing/AGENTS.md"
  assert_eq "branch checked out" "feat/thing" \
    "$(git -C "$SB_TASKS/feat-thing/backend" rev-parse --abbrev-ref HEAD)"
  assert_grep "repos listed in context" "backend" "$SB_TASKS/feat-thing/CLAUDE.md"
  # --no-track: a fresh branch must have no upstream.
  assert_fails "no upstream on fresh branch" \
    git -C "$SB_TASKS/feat-thing/backend" rev-parse --abbrev-ref '@{upstream}'
}

test_baseline_rm_removes_task() {
  mk_repo backend
  iw feat/gone -r backend >/dev/null 2>&1
  iw rm -f feat-gone >/dev/null 2>&1

  assert_no_file "task folder gone" "$SB_TASKS/feat-gone"
  assert_ok "branch survives rm" \
    git -C "$SB_REPOS/backend" show-ref --verify --quiet refs/heads/feat/gone
}

test_baseline_list_repos_excludes_tasks_dir() {
  mk_repo backend
  local out
  out="$(iw --complete-repos "" 2>/dev/null)"
  assert_contains "repo listed" "backend" "$out"
  assert_eq "only the repo is listed" "backend" "$out"
}

# --- --from (from main) must survive the project changes ----------------------
#
# The creation path used to strip --from before parse_repos_flag; it now goes
# through parse_task_args, which rejects unknown options. Nothing on main tested
# --from, so these exist to prove the rewrite did not half-break it.

test_from_after_the_branch_name() {
  mk_repo backend
  iw feat/base -r backend >/dev/null 2>&1
  ( cd "$SB_TASKS/feat-base/backend" && echo "base work" > base.txt &&
    git add -A && git commit -qm "base commit" )

  iw feat/stacked --from feat-base -r backend >/dev/null 2>&1

  assert_dir "stacked task created" "$SB_TASKS/feat-stacked"
  assert_file "base commit is in the history" "$SB_TASKS/feat-stacked/backend/base.txt"
}

test_from_before_the_branch_name() {
  mk_repo backend
  iw feat/base -r backend >/dev/null 2>&1
  ( cd "$SB_TASKS/feat-base/backend" && echo "base work" > base.txt &&
    git add -A && git commit -qm "base commit" )

  # The leading-flag loop, which the project work did not touch.
  iw --from feat-base feat/stacked -r backend >/dev/null 2>&1
  assert_file "base commit is in the history" "$SB_TASKS/feat-stacked/backend/base.txt"
}

test_from_combines_with_project_in_any_order() {
  mk_repo backend
  iw feat/base -r backend >/dev/null 2>&1
  ( cd "$SB_TASKS/feat-base/backend" && echo "base work" > base.txt &&
    git add -A && git commit -qm "base commit" )

  iw feat/one --from feat-base -r backend -p myproj >/dev/null 2>&1
  assert_file "stacked and attached: base work present" \
    "$SB_TASKS/feat-one/backend/base.txt"
  assert_link "stacked and attached: project linked" "$SB_TASKS/feat-one/.project"

  # -p first, --from last, repos in the middle.
  iw feat/two -p myproj -r backend --from feat-base >/dev/null 2>&1
  assert_file "order does not matter: base work present" \
    "$SB_TASKS/feat-two/backend/base.txt"
  assert_link "order does not matter: project linked" "$SB_TASKS/feat-two/.project"
}

test_from_records_the_base_in_task_context() {
  mk_repo backend
  iw feat/base -r backend >/dev/null 2>&1
  iw feat/stacked --from feat-base -r backend -p myproj >/dev/null 2>&1

  # main renders {{BASE}} into the template; the project block is appended after
  # it. Both must survive together.
  assert_grep "base recorded for the agent" "feat-base" \
    "$SB_TASKS/feat-stacked/CLAUDE.md"
  assert_grep "project block still injected" "iwork:project" \
    "$SB_TASKS/feat-stacked/CLAUDE.md"
  assert_grep "repos block still injected" "iwork:repos" \
    "$SB_TASKS/feat-stacked/CLAUDE.md"
}

test_from_on_add_repo() {
  mk_repo backend
  mk_repo frontend
  iw feat/base -r frontend >/dev/null 2>&1
  ( cd "$SB_TASKS/feat-base/frontend" && echo "base work" > base.txt &&
    git add -A && git commit -qm "base commit" )
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  iw add-repo feat-one --from feat-base -r frontend >/dev/null 2>&1
  assert_dir "add-repo --from created the worktree" "$SB_TASKS/feat-one/frontend"
  assert_file "add-repo --from used the base" "$SB_TASKS/feat-one/frontend/base.txt"
  assert_grep "repos block refreshed after add-repo" "frontend" \
    "$SB_TASKS/feat-one/CLAUDE.md"
}

test_from_rejects_a_swallowed_flag() {
  mk_repo backend
  # 'iwork feat/x --from -p proj -r backend' must not take '-p' as the base.
  assert_fails "--from refuses a flag as its value" \
    iw feat/one --from -p myproj -r backend
  assert_fails "--from with nothing after it fails" iw feat/one -r backend --from
  assert_fails "unresolvable base fails" iw feat/one --from nope-not-a-thing -r backend
  assert_no_file "no task left behind" "$SB_TASKS/feat-one"
}

test_project_flag_rejects_a_swallowed_flag() {
  mk_repo backend
  # The project name regex allows '-', so without an explicit guard this would
  # create a project literally called '--from'.
  assert_fails "-p refuses a flag as its value" \
    iw feat/one -r backend -p --from feat-base
  assert_no_file "no project named after a flag" "$SB_PROJECTS/--from"
  assert_fails "-p with nothing after it fails" iw feat/one -r backend -p
}

test_unknown_option_still_rejected() {
  mk_repo backend
  assert_fails "a genuinely unknown flag is still an error" \
    iw feat/one -r backend --frobnicate
}

# --- projects dir ------------------------------------------------------------

test_project_created_on_first_use() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  assert_dir "project dir created" "$SB_PROJECTS/myproj"
  assert_file "PROJECT.md seeded" "$SB_PROJECTS/myproj/PROJECT.md"
  assert_file "LOG.md seeded" "$SB_PROJECTS/myproj/LOG.md"
  assert_file "TODO.md seeded" "$SB_PROJECTS/myproj/TODO.md"
  assert_file "history.tsv seeded" "$SB_PROJECTS/myproj/history.tsv"
  assert_dir "notes/ seeded" "$SB_PROJECTS/myproj/notes"
  assert_grep "opened event recorded" "opened" "$SB_PROJECTS/myproj/history.tsv"
  assert_grep "opened event names the task" "feat-one" "$SB_PROJECTS/myproj/history.tsv"
}

test_project_flag_before_repos_flag() {
  mk_repo backend
  iw feat/two -p myproj -r backend >/dev/null 2>&1
  assert_dir "project created with -p before -r" "$SB_PROJECTS/myproj"
  assert_link "task linked" "$SB_TASKS/feat-two/.project"
}

test_project_reused_by_second_task() {
  mk_repo backend
  mk_repo frontend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  printf 'hand-written goal\n' >> "$SB_PROJECTS/myproj/PROJECT.md"
  iw feat/two -r frontend -p myproj >/dev/null 2>&1

  assert_grep "second task did not reseed PROJECT.md" "hand-written goal" \
    "$SB_PROJECTS/myproj/PROJECT.md"
  assert_link "second task linked" "$SB_TASKS/feat-two/.project"
  assert_eq "two opened events" "2" \
    "$(grep -c 'opened' "$SB_PROJECTS/myproj/history.tsv")"
}

test_project_symlink_points_at_project() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  assert_link ".project is a symlink" "$SB_TASKS/feat-one/.project"
  assert_eq "symlink resolves to project dir" \
    "$(cd "$SB_PROJECTS/myproj" && pwd -P)" \
    "$(cd "$SB_TASKS/feat-one/.project" && pwd -P)"
  # The dot prefix is load-bearing: every child glob in iwork uses *, so the
  # link must stay invisible to worktree enumeration.
  local out
  out="$(iw --complete-task-worktrees feat-one "" 2>/dev/null)"
  assert_eq "symlink invisible to worktree listing" "backend" "$out"
}

test_project_name_collides_with_task() {
  mk_repo backend
  iw feat/clash -r backend >/dev/null 2>&1
  assert_fails "project named after an existing task is refused" \
    iw feat/other -r backend -p feat-clash
}

test_project_bad_name_refused() {
  mk_repo backend
  assert_fails "slash in project name refused" iw feat/x -r backend -p 'a/b'
  assert_fails "empty project name refused" iw feat/x -r backend -p ''
  assert_fails "marker prefix refused" iw feat/x -r backend -p '*bad'
}

test_projects_dir_not_listed_as_repo() {
  mk_repo backend
  # Phase 3 will git init the project dir; make sure it can never show up as a
  # selectable repo even then.
  mkdir -p "$SB_REPOS/projects"
  git init -q -b main "$SB_REPOS/projects"
  local out
  out="$(env IWORK_PROJECTS_DIR="$SB_REPOS/projects" \
    HOME="$SB_HOME" GIT_CONFIG_GLOBAL="$SB_HOME/.gitconfig" \
    IWORK_CONFIG_FILE="$SB/config" IWORK_REPO_DIR="$SB_REPOS" \
    IWORK_TASKS_DIR="$SB_TASKS" IWORK_NO_TMUX=1 \
    "$IWORK_SRC" --complete-repos "" 2>/dev/null)"
  assert_eq "projects dir excluded from repo list" "backend" "$out"
}

# --- injected context block ---------------------------------------------------

test_marker_block_written_to_both_context_files() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  local f
  for f in CLAUDE.md AGENTS.md; do
    assert_grep "open marker in $f" "iwork:project" "$SB_TASKS/feat-one/$f"
    assert_grep "project named in $f" "myproj" "$SB_TASKS/feat-one/$f"
    assert_grep "entry point named in $f" "iwork project show" "$SB_TASKS/feat-one/$f"
    assert_grep "capture verb named in $f" "iwork todo" "$SB_TASKS/feat-one/$f"
    assert_grep "grep verb named in $f" "iwork project grep" "$SB_TASKS/feat-one/$f"
  done
}

test_marker_block_is_idempotent() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw project add myproj feat-one >/dev/null 2>&1
  iw project add myproj feat-one >/dev/null 2>&1

  assert_eq "exactly one open marker" "1" \
    "$(grep -c '<!-- iwork:project -->' "$SB_TASKS/feat-one/CLAUDE.md")"
  assert_eq "exactly one close marker" "1" \
    "$(grep -c '<!-- /iwork:project -->' "$SB_TASKS/feat-one/CLAUDE.md")"
}

test_marker_block_preserves_hand_edits() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  printf '\nMY OWN NOTE\n' >> "$SB_TASKS/feat-one/CLAUDE.md"
  iw project add myproj feat-one >/dev/null 2>&1

  assert_grep "hand edit survives a refresh" "MY OWN NOTE" "$SB_TASKS/feat-one/CLAUDE.md"
}

test_add_repo_refreshes_repos_block() {
  mk_repo backend
  mk_repo frontend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  assert_no_grep "frontend absent before add-repo" "frontend" "$SB_TASKS/feat-one/CLAUDE.md"

  iw add-repo feat-one -r frontend >/dev/null 2>&1
  assert_grep "add-repo refreshed the repos block" "frontend" "$SB_TASKS/feat-one/CLAUDE.md"
  assert_grep "existing repo still listed" "backend" "$SB_TASKS/feat-one/CLAUDE.md"
}

# --- capture: todo / log / decided -------------------------------------------

test_todo_infers_project_from_cwd() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" todo "needs backoff" >/dev/null 2>&1

  assert_grep "todo appended" "needs backoff" "$SB_PROJECTS/myproj/TODO.md"
  assert_grep "todo is unchecked" '^- \[ \]' "$SB_PROJECTS/myproj/TODO.md"
  assert_grep "todo attributed to task" "feat-one" "$SB_PROJECTS/myproj/TODO.md"
}

test_todo_works_from_inside_a_worktree() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  mkdir -p "$SB_TASKS/feat-one/backend/src/deep"
  iw_in "$SB_TASKS/feat-one/backend/src/deep" todo "found deep down" >/dev/null 2>&1

  assert_grep "todo captured from a nested dir" "found deep down" \
    "$SB_PROJECTS/myproj/TODO.md"
}

test_todo_outside_a_task_fails_clearly() {
  mk_repo backend
  local out
  out="$(iw_in "$SB" todo "orphan" 2>&1)"
  assert_contains "error names the fix" "-p" "$out"
  assert_fails "capture outside a task fails" iw_in "$SB" todo "orphan"
}

test_log_and_decided_share_one_file() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" decided "cursor pagination, not offset" >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" log --shipped "backend#412" >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" log --decision "retry twice" >/dev/null 2>&1

  assert_grep "decided landed in LOG.md" "cursor pagination" "$SB_PROJECTS/myproj/LOG.md"
  assert_grep "shipped landed in LOG.md" "backend#412" "$SB_PROJECTS/myproj/LOG.md"
  assert_grep "decided is labelled" "decision" "$SB_PROJECTS/myproj/LOG.md"
  assert_grep "shipped is labelled" "shipped" "$SB_PROJECTS/myproj/LOG.md"
  assert_eq "three entries, one file" "3" \
    "$(grep -c '^- ' "$SB_PROJECTS/myproj/LOG.md")"
}

test_entries_carry_a_time_not_just_a_date() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" decided "first thing" >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" decided "second thing" >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" todo "a todo" >/dev/null 2>&1

  # Date alone made several entries from one day indistinguishable.
  assert_grep "log entries are stamped with a time" \
    '^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]  ' \
    "$SB_PROJECTS/myproj/LOG.md"
  assert_eq "both entries stamped" "2" \
    "$(grep -c '^- [0-9-]* [0-9][0-9]:[0-9][0-9]  ' "$SB_PROJECTS/myproj/LOG.md")"
  assert_grep "todos too" ', [0-9-]* [0-9][0-9]:[0-9][0-9]$' "$SB_PROJECTS/myproj/TODO.md"

  # The time must reach the reader, not just the file.
  assert_contains "project show surfaces the time" ":" \
    "$(iw project show myproj 2>&1 | grep 'first thing')"
}

test_time_stamps_do_not_break_the_parsers() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" todo "close me" >/dev/null 2>&1
  local id
  id="$(sed -n 's/.*(\(t[0-9a-f]*\)).*/\1/p' "$SB_PROJECTS/myproj/TODO.md" | head -1)"

  # The id sits before the stamp, and every reader keys off the line prefix.
  assert_ok "done still finds the todo" iw_in "$SB_TASKS/feat-one" "done" "$id"
  assert_grep "and flipped it" '\[x\].*close me' "$SB_PROJECTS/myproj/TODO.md"

  # A pre-existing date-only entry must still be counted and displayed.
  printf -- '- 2026-01-01  feat-one  decision: written by an older iwork\n' \
    >> "$SB_PROJECTS/myproj/LOG.md"
  local out
  out="$(iw project show myproj 2>&1)"
  assert_contains "old date-only entries still shown" "written by an older iwork" "$out"
}

test_capture_is_single_line() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" decided "$(printf 'line one\nline two\nline three')" >/dev/null 2>&1

  assert_eq "multi-line prose collapses to one line" "1" \
    "$(grep -c '^- ' "$SB_PROJECTS/myproj/LOG.md")"
  assert_grep "no content lost" "line three" "$SB_PROJECTS/myproj/LOG.md"
}

test_capture_survives_shell_metacharacters() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" todo 'use $HOME and `date` and "quotes" and *glob*' >/dev/null 2>&1

  assert_grep "dollar survived" 'use \$HOME' "$SB_PROJECTS/myproj/TODO.md"
  assert_grep "backticks survived" '`date`' "$SB_PROJECTS/myproj/TODO.md"
}

test_parallel_captures_do_not_clobber() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  local i
  local pids=()
  for i in $(seq 1 20); do
    iw_in "$SB_TASKS/feat-one" todo "concurrent item $i" >/dev/null 2>&1 &
    pids+=($!)
  done
  # Named pids, not a bare 'wait': the latter would also wait on the watchdog.
  wait "${pids[@]}"

  assert_eq "all 20 appends landed" "20" \
    "$(grep -c '^- \[ \]' "$SB_PROJECTS/myproj/TODO.md")"
  assert_eq "every todo got a distinct id" "20" \
    "$(grep -o '(t[0-9a-f]*)' "$SB_PROJECTS/myproj/TODO.md" | sort -u | wc -l | tr -d ' ')"
}

test_parallel_log_appends_do_not_clobber() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  local i
  local pids=()
  for i in $(seq 1 20); do
    iw_in "$SB_TASKS/feat-one" decided "concurrent decision $i" >/dev/null 2>&1 &
    pids+=($!)
  done
  wait "${pids[@]}"

  assert_eq "all 20 log appends landed" "20" \
    "$(grep -c '^- ' "$SB_PROJECTS/myproj/LOG.md")"
}

# --- todo lifecycle ----------------------------------------------------------

test_done_flips_the_checkbox() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" todo "first thing" >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" todo "second thing" >/dev/null 2>&1

  local id
  id="$(grep 'first thing' "$SB_PROJECTS/myproj/TODO.md" | sed -n 's/.*(\(t[0-9a-f]*\)).*/\1/p')"
  iw_in "$SB_TASKS/feat-one" "done" "$id" >/dev/null 2>&1

  assert_grep "target todo is checked" "\[x\].*first thing" "$SB_PROJECTS/myproj/TODO.md"
  assert_grep "other todo untouched" "\[ \].*second thing" "$SB_PROJECTS/myproj/TODO.md"
  assert_eq "no lines lost" "2" "$(grep -c '^- \[' "$SB_PROJECTS/myproj/TODO.md")"
}

test_done_with_unknown_id_fails_loudly() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" todo "a thing" >/dev/null 2>&1

  assert_fails "unknown id is an error" iw_in "$SB_TASKS/feat-one" "done" tdead
  assert_grep "file untouched after failed flip" '^- \[ \]' "$SB_PROJECTS/myproj/TODO.md"
}

test_drop_marks_without_completing() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" todo "wont do this" >/dev/null 2>&1
  local id
  id="$(sed -n 's/.*(\(t[0-9a-f]*\)).*/\1/p' "$SB_PROJECTS/myproj/TODO.md" | head -1)"
  iw_in "$SB_TASKS/feat-one" drop "$id" >/dev/null 2>&1

  assert_grep "dropped todo is marked distinctly" "\[-\].*wont do this" \
    "$SB_PROJECTS/myproj/TODO.md"
}

test_stale_lock_does_not_wedge_capture() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" todo "a thing" >/dev/null 2>&1
  local id
  id="$(sed -n 's/.*(\(t[0-9a-f]*\)).*/\1/p' "$SB_PROJECTS/myproj/TODO.md" | head -1)"

  # A killed agent leaves a lockdir with a pid that no longer exists.
  mkdir -p "$SB_PROJECTS/myproj/.lock"
  echo "999999" > "$SB_PROJECTS/myproj/.lock/pid"

  assert_ok "stale lock is broken, not waited on" \
    iw_in "$SB_TASKS/feat-one" "done" "$id"
  assert_grep "flip actually happened" "\[x\]" "$SB_PROJECTS/myproj/TODO.md"
}

test_capture_ignores_lock_entirely() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  # A held lock must not block the one operation that has to never derail a
  # session: appends are lock-free by design.
  mkdir -p "$SB_PROJECTS/myproj/.lock"
  echo "$$" > "$SB_PROJECTS/myproj/.lock/pid"

  assert_ok "capture works while the lock is held" \
    iw_in "$SB_TASKS/feat-one" todo "captured under lock"
  assert_grep "todo landed" "captured under lock" "$SB_PROJECTS/myproj/TODO.md"
  rm -rf "$SB_PROJECTS/myproj/.lock"
}

# --- project show / grep ------------------------------------------------------

test_project_show_assembles_state() {
  mk_repo backend
  mk_repo frontend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw feat/two -r frontend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" decided "cursor pagination" >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" todo "needs backoff" >/dev/null 2>&1

  local out
  out="$(iw_in "$SB_TASKS/feat-one" project show 2>&1)"
  assert_contains "names the project" "myproj" "$out"
  assert_contains "lists the open todo" "needs backoff" "$out"
  assert_contains "lists the decision" "cursor pagination" "$out"
  assert_contains "lists this task" "feat-one" "$out"
  assert_contains "lists the sibling task" "feat-two" "$out"
}

test_project_show_derives_live_tasks() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  # Nuke a task the way a human would, behind iwork's back. Live state is
  # derived, so show must simply stop reporting it.
  rm -rf "$SB_TASKS/feat-one"

  local out
  out="$(iw project show myproj 2>&1)"
  assert_ok "show survives a hand-deleted task" iw project show myproj
  assert_contains "history still remembers the task" "feat-one" "$out"
}

test_project_show_closed_todos_hidden() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" todo "open item" >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" todo "closed item" >/dev/null 2>&1
  local id
  id="$(grep 'closed item' "$SB_PROJECTS/myproj/TODO.md" | sed -n 's/.*(\(t[0-9a-f]*\)).*/\1/p')"
  iw_in "$SB_TASKS/feat-one" "done" "$id" >/dev/null 2>&1

  local out
  out="$(iw project show myproj 2>&1)"
  assert_contains "open todo shown" "open item" "$out"
  case "$out" in
    *"closed item"*) bad "completed todo should not be in the open list" ;;
    *) ok ;;
  esac
}

test_project_grep_finds_hidden_symlinked_notes() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  echo "ZORBLAX lives here" > "$SB_PROJECTS/myproj/notes/design.md"

  # Plain rg from the task root cannot see this: .project is hidden AND a
  # symlink, so recursive traversal skips it twice over. That is the whole
  # reason `project grep` exists.
  if command -v rg >/dev/null 2>&1; then
    local raw
    # The path matters: given no path and a piped stdin, rg searches stdin
    # instead of the directory, and hangs the suite if nothing ever closes it.
    raw="$( cd "$SB_TASKS/feat-one" && rg ZORBLAX . 2>/dev/null )"
    assert_eq "plain rg cannot see project notes" "" "$raw"
  fi

  local out
  out="$(iw_in "$SB_TASKS/feat-one" project grep ZORBLAX 2>&1)"
  assert_contains "project grep finds it" "ZORBLAX" "$out"
  assert_contains "project grep names the file" "design.md" "$out"
}

test_project_list() {
  mk_repo backend
  iw feat/one -r backend -p alpha >/dev/null 2>&1
  iw feat/two -r backend -p beta >/dev/null 2>&1 || true
  local out
  out="$(iw project list 2>&1)"
  assert_contains "alpha listed" "alpha" "$out"
  assert_contains "beta listed" "beta" "$out"
}

# --- retrofit: project add / rm ------------------------------------------------

test_project_add_retrofits_existing_task() {
  mk_repo backend
  iw feat/old -r backend >/dev/null 2>&1
  assert_no_file "no link before retrofit" "$SB_TASKS/feat-old/.project"

  iw project add myproj feat-old >/dev/null 2>&1
  assert_link "link created by retrofit" "$SB_TASKS/feat-old/.project"
  assert_grep "block injected by retrofit" "iwork:project" "$SB_TASKS/feat-old/CLAUDE.md"
  assert_grep "AGENTS.md too" "iwork:project" "$SB_TASKS/feat-old/AGENTS.md"
  assert_grep "opened event backfilled" "feat-old" "$SB_PROJECTS/myproj/history.tsv"
  assert_ok "capture works after retrofit" iw_in "$SB_TASKS/feat-old" todo "found later"
}

test_project_add_refuses_second_project() {
  mk_repo backend
  iw feat/one -r backend -p alpha >/dev/null 2>&1
  assert_fails "one project per task" iw project add beta feat-one
  assert_eq "still attached to the original" "alpha" \
    "$(basename "$(cd "$SB_TASKS/feat-one/.project" && pwd -P)")"
  # The refusal has to come before the project is created, or a rejected attach
  # leaves a directory behind that nothing references.
  assert_no_file "no stray project from the refused attach" "$SB_PROJECTS/beta"
}

test_project_rm_detaches_but_keeps_memory() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" decided "worth keeping" >/dev/null 2>&1
  iw project rm myproj feat-one >/dev/null 2>&1

  assert_no_file "link removed" "$SB_TASKS/feat-one/.project"
  assert_no_grep "block removed from CLAUDE.md" "iwork:project" "$SB_TASKS/feat-one/CLAUDE.md"
  assert_file "task itself untouched" "$SB_TASKS/feat-one/CLAUDE.md"
  assert_dir "worktree untouched" "$SB_TASKS/feat-one/backend"
  assert_grep "memory survives detach" "worth keeping" "$SB_PROJECTS/myproj/LOG.md"
}

test_project_delete_requires_force() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  assert_fails "delete refuses while a task is attached" iw project delete myproj
  assert_dir "project still there" "$SB_PROJECTS/myproj"
}

# --- rm interaction ----------------------------------------------------------

test_rm_cleans_symlink_and_removes_folder() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw rm -f feat-one >/dev/null 2>&1

  # The bug this guards: a leftover .project link makes the rmdir at the end of
  # remove_worktrees fail, leaving the task folder behind on every project task.
  assert_no_file "task folder fully removed" "$SB_TASKS/feat-one"
  assert_dir "project memory survives rm" "$SB_PROJECTS/myproj"
  assert_file "LOG.md survives rm" "$SB_PROJECTS/myproj/LOG.md"
}

test_rm_does_not_follow_symlink() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  echo "precious" > "$SB_PROJECTS/myproj/notes/keep.md"
  iw rm -f feat-one >/dev/null 2>&1

  assert_file "notes not deleted through the link" "$SB_PROJECTS/myproj/notes/keep.md"
  assert_dir "notes dir intact" "$SB_PROJECTS/myproj/notes"
}

test_rm_records_closed_event() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw rm -f feat-one >/dev/null 2>&1

  assert_grep "closed event appended" "closed" "$SB_PROJECTS/myproj/history.tsv"
  assert_grep "closed event names the branch" "feat/one" "$SB_PROJECTS/myproj/history.tsv"
  assert_eq "history is append-only: both events kept" "2" \
    "$(grep -c 'feat-one' "$SB_PROJECTS/myproj/history.tsv")"
}

test_rm_single_repo_keeps_project_link() {
  mk_repo backend
  mk_repo frontend
  iw feat/one -r backend frontend -p myproj >/dev/null 2>&1
  iw rm -f feat-one -r frontend >/dev/null 2>&1

  assert_link "link kept when only one repo is removed" "$SB_TASKS/feat-one/.project"
  assert_no_grep "no premature closed event" "closed" "$SB_PROJECTS/myproj/history.tsv"
  assert_no_grep "repos block refreshed" "frontend" "$SB_TASKS/feat-one/CLAUDE.md"
}

# --- tmux / hook -------------------------------------------------------------

test_hook_marks_project_window() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  tmux_t new-session -d -s tasks -n myproj -c "$SB_PROJECTS/myproj" 2>/dev/null
  local pane socket
  pane="$(tmux_t list-panes -t tasks -F '#{pane_id}' 2>/dev/null | head -1)"
  socket="$(tmux_t display-message -p '#{socket_path}' 2>/dev/null)"
  if [[ -z "$pane" || -z "$socket" ]]; then
    printf '    skip (could not start isolated tmux server)\n'
    return 0
  fi

  printf '{"hook_event_name":"UserPromptSubmit"}' | env \
    TMUX="$socket,1,0" TMUX_PANE="$pane" TMUX_TMPDIR="$SB/tmux" \
    HOME="$SB_HOME" IWORK_CONFIG_FILE="$SB/config" \
    IWORK_REPO_DIR="$SB_REPOS" IWORK_TASKS_DIR="$SB_TASKS" \
    IWORK_PROJECTS_DIR="$SB_PROJECTS" \
    "$IWORK_SRC" --hook >/dev/null 2>&1

  assert_eq "project window gets the busy marker" "*myproj" \
    "$(tmux_t display-message -p -t "$pane" '#{window_name}' 2>/dev/null)"
}

test_hook_still_marks_task_window() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  iw feat/one -r backend >/dev/null 2>&1

  tmux_t new-session -d -s tasks -n feat-one -c "$SB_TASKS/feat-one" 2>/dev/null
  local pane socket
  pane="$(tmux_t list-panes -t tasks -F '#{pane_id}' 2>/dev/null | head -1)"
  socket="$(tmux_t display-message -p '#{socket_path}' 2>/dev/null)"
  if [[ -z "$pane" || -z "$socket" ]]; then
    printf '    skip (could not start isolated tmux server)\n'
    return 0
  fi

  printf '{"hook_event_name":"Stop"}' | env \
    TMUX="$socket,1,0" TMUX_PANE="$pane" TMUX_TMPDIR="$SB/tmux" \
    HOME="$SB_HOME" IWORK_CONFIG_FILE="$SB/config" \
    IWORK_REPO_DIR="$SB_REPOS" IWORK_TASKS_DIR="$SB_TASKS" \
    IWORK_PROJECTS_DIR="$SB_PROJECTS" \
    "$IWORK_SRC" --hook >/dev/null 2>&1

  assert_eq "task window still gets the waiting marker" "!feat-one" \
    "$(tmux_t display-message -p -t "$pane" '#{window_name}' 2>/dev/null)"
}

# --- completions --------------------------------------------------------------

test_completion_scripts_are_valid_shell() {
  local out
  out="$(iw --completion bash 2>&1)"
  assert_ok "bash completion parses" bash -n <(printf '%s' "$out")
  assert_contains "project subcommand offered" "project" "$out"
  out="$(iw --completion zsh 2>&1)"
  assert_contains "zsh completion mentions project" "project" "$out"
}

test_complete_projects_helper() {
  mk_repo backend
  iw feat/one -r backend -p alpha >/dev/null 2>&1
  local out
  out="$(iw --complete-projects "" 2>/dev/null)"
  assert_contains "project completion works" "alpha" "$out"
}

test_checkpoint_nudge_appears_after_growth() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  local i
  for i in $(seq 1 45); do
    printf -- '- 2026-08-20  feat-one  note: entry %s\n' "$i" >> "$SB_PROJECTS/myproj/LOG.md"
  done

  local out
  out="$(iw project show myproj 2>&1)"
  assert_contains "nudge appears once the log outgrows the window" \
    "log entries since the last checkpoint" "$out"

  printf -- '- 2026-08-20  feat-one  checkpoint: condensed into PROJECT.md\n' \
    >> "$SB_PROJECTS/myproj/LOG.md"
  out="$(iw project show myproj 2>&1)"
  case "$out" in
    *"log entries since the last checkpoint"*) bad "nudge should reset after a checkpoint" ;;
    *) ok ;;
  esac
}

test_project_creation_failure_leaves_no_task() {
  mk_repo backend
  # If the project cannot be created, the confirm-and-create step must fail
  # before any worktree exists, so there is nothing to clean up by hand.
  chmod 500 "$SB_PROJECTS"
  assert_fails "creation fails when the project dir is unwritable" \
    iw feat/one -r backend -p myproj
  chmod 700 "$SB_PROJECTS"

  assert_no_file "no half-created task left behind" "$SB_TASKS/feat-one"
  assert_no_file "no half-created project left behind" "$SB_PROJECTS/myproj"
}

test_park_with_project() {
  mk_repo backend
  git -C "$SB_REPOS/backend" checkout -q -b feat/parked
  echo "work in progress" > "$SB_REPOS/backend/wip.txt"

  ( cd "$SB_REPOS/backend" && iw park parked-task -p myproj ) >/dev/null 2>&1

  assert_dir "parked task created" "$SB_TASKS/parked-task"
  assert_link "parked task joined the project" "$SB_TASKS/parked-task/.project"
  assert_grep "opened event recorded" "parked-task" "$SB_PROJECTS/myproj/history.tsv"
  assert_file "stashed work restored" "$SB_TASKS/parked-task/backend/wip.txt"
}

# The gap that made every agent-facing verb unreachable: an agent's shell
# inherits these functions from a Claude Code shell snapshot, which captures the
# function but not the '_iwork_bin=' assignment emitted next to it. The wrapper
# then executed the empty string. Every other test in this file calls the binary
# directly, so nothing here would have noticed.
test_wrapper_works_without_iwork_bin_set() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  local shell=""
  local out=""
  for shell in bash zsh; do
    command -v "$shell" >/dev/null 2>&1 || continue
    iw --completion "$shell" > "$SB/wrapper-$shell.sh" 2>/dev/null

    # PATH-resolvable iwork, no _iwork_bin — exactly the snapshot situation.
    out="$("$shell" -c "
      export PATH='$SB/bin':\$PATH
      ln -sf '$IWORK_SRC' '$SB/bin/iwork'
      source '$SB/wrapper-$shell.sh'
      unset _iwork_bin
      export IWORK_CONFIG_FILE='$SB/config' IWORK_REPO_DIR='$SB_REPOS'
      export IWORK_TASKS_DIR='$SB_TASKS' IWORK_PROJECTS_DIR='$SB_PROJECTS'
      export IWORK_NO_TMUX=1 HOME='$SB_HOME'
      iwork list
    " 2>&1)"
    assert_contains "$shell wrapper works with _iwork_bin unset" "feat-one" "$out"
    case "$out" in
      *"permission denied"*) bad "$shell wrapper tried to execute the empty string" ;;
      *) ok ;;
    esac
  done
}

test_wrapper_says_so_when_the_binary_is_missing() {
  mk_repo backend
  iw --completion bash > "$SB/wrapper.sh" 2>/dev/null

  # No _iwork_bin and nothing on PATH: an actionable message, not a silent fail.
  local out
  out="$(bash -c "
    source '$SB/wrapper.sh'
    unset _iwork_bin
    PATH=/usr/bin:/bin
    iwork list
    echo \"exit=\$?\"
  " 2>&1)"
  assert_contains "the message names the fix" "re-source the shell integration" "$out"
  assert_contains "and it exits 127" "exit=127" "$out"
}

test_completion_helpers_also_resolve_the_binary() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw --completion bash > "$SB/wrapper.sh" 2>/dev/null

  # The completion function calls the binary too; patching only the wrapper
  # would have left tab completion silently returning nothing.
  local out
  out="$(bash -c "
    export PATH='$SB/bin':\$PATH
    ln -sf '$IWORK_SRC' '$SB/bin/iwork'
    source '$SB/wrapper.sh'
    unset _iwork_bin
    export IWORK_CONFIG_FILE='$SB/config' IWORK_REPO_DIR='$SB_REPOS'
    export IWORK_TASKS_DIR='$SB_TASKS' IWORK_PROJECTS_DIR='$SB_PROJECTS'
    export IWORK_NO_TMUX=1 HOME='$SB_HOME'
    COMP_WORDS=(iwork cd '') COMP_CWORD=2
    _iwork
    printf '%s\n' \"\${COMPREPLY[@]}\"
  " 2>&1)"
  assert_contains "completion still produces candidates" "feat-one" "$out"
}

test_park_wrapper_forwards_flags() {
  local out
  for shell in bash zsh; do
    out="$(iw --completion "$shell" 2>&1)"
    assert_contains "$shell wrapper forwards every park arg" 'park "$@"' "$out"
    assert_contains "$shell wrapper does not assume the task is \$2" 'skip_next' "$out"
  done
}

# Behavioural, not textual: the wrapper has to find the task name in order to cd
# there, and 'park -p proj task' puts it in $3. Getting this wrong left the user
# in the wrong directory with a non-zero status, while park itself succeeded.
test_park_wrapper_finds_the_task_after_a_flag() {
  local shim="$SB/shim"
  cat > "$shim" <<SHIM
#!/usr/bin/env bash
if [[ "\$1" == "--resolve-park-target-path" ]]; then
  echo "resolve:\$2" >> "$SB/calls"
  echo "$SB"
  exit 0
fi
printf 'run:%s\n' "\$*" >> "$SB/calls"
SHIM
  chmod +x "$shim"

  : > "$SB/calls"
  iw --completion bash > "$SB/wrapper.sh" 2>/dev/null
  ( . "$SB/wrapper.sh" >/dev/null 2>&1
    _iwork_bin="$shim"
    iwork park -p myproj mytask >/dev/null 2>&1 )

  assert_grep "wrapper resolved the task, not the flag" '^resolve:mytask$' "$SB/calls"
  assert_grep "wrapper forwarded both the flag and the task" 'run:park -p myproj mytask' \
    "$SB/calls"
  assert_no_grep "wrapper did not treat '-p' as the task" '^resolve:-p$' "$SB/calls"
}

# --- CLI-only access to project memory ----------------------------------------

test_project_cat_reads_a_file() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  echo "token TTL is 15 minutes" > "$SB_PROJECTS/myproj/notes/api.md"

  local out
  out="$(iw_in "$SB_TASKS/feat-one" project cat notes/api.md 2>&1)"
  assert_contains "cat reads a note" "token TTL is 15 minutes" "$out"

  out="$(iw_in "$SB_TASKS/feat-one" project cat LOG.md 2>&1)"
  assert_contains "cat reads the log" "Log — myproj" "$out"
}

test_project_cat_refuses_to_escape() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  echo "secret" > "$SB/outside.txt"

  # This is the read primitive that replaces direct access to .project/, so it
  # must not become a way out of the project directory.
  assert_fails "parent traversal refused" \
    iw_in "$SB_TASKS/feat-one" project cat ../../outside.txt
  assert_fails "absolute path refused" \
    iw_in "$SB_TASKS/feat-one" project cat /etc/hosts
  assert_fails "missing file is an error" \
    iw_in "$SB_TASKS/feat-one" project cat notes/nope.md

  # ...but a dotted filename is not traversal.
  echo "fine" > "$SB_PROJECTS/myproj/notes/v1..2.md"
  assert_ok "dotted filename still readable" \
    iw_in "$SB_TASKS/feat-one" project cat "notes/v1..2.md"
}

test_project_show_n_limits_the_log() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  local i
  for i in $(seq 1 20); do
    printf -- '- 2026-08-20  feat-one  note: entry %s\n' "$i" >> "$SB_PROJECTS/myproj/LOG.md"
  done

  local out
  out="$(iw project show -n 3 myproj 2>&1)"
  assert_contains "last entry shown" "entry 20" "$out"
  case "$out" in
    *"entry 17"*) bad "-n 3 should not reach entry 17" ;;
    *) ok ;;
  esac
  assert_fails "-n needs a number" iw project show -n zero myproj
}

test_template_routes_access_through_the_cli() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  local f="$SB_TASKS/feat-one/CLAUDE.md"

  # Writes are a hard rule and must come with the concurrency reason: an agent
  # that can see .project sitting in ls will discount a rule it can tell is
  # false, and discount the rest of the block with it.
  assert_grep "hand-writing forbidden" "Never write to those files by hand" "$f"
  assert_grep "reason given for the write rule" "sibling tasks are appending" "$f"
  assert_grep "read commands offered" "iwork project cat" "$f"
  assert_grep "reachability stated honestly" "reachable from here" "$f"

  # The claims that were false: the memory is not outside the task directory,
  # and the scope rule never forbade it.
  assert_no_grep "no claim that the memory is outside the task dir" \
    "lives outside this task directory" "$f"
  assert_no_grep "no blanket prohibition on reading" "do not read, edit, search" "$f"
}

test_template_points_at_scoped_help_and_draws_the_boundary() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  local f="$SB_TASKS/feat-one/CLAUDE.md"

  assert_grep "says iwork is a CLI" "CLI on your PATH" "$f"
  assert_grep "points at scoped help, not iwork -h" "iwork project -h" "$f"
  assert_grep "names the operator-only commands" "belongs to the operator" "$f"
  # 'iwork -h' is 180 lines of mostly operator material and advertises 'rm -f';
  # the block must not send an agent there.
  assert_no_grep "does not send the agent to the full help" 'run .iwork -h' "$f"
}

test_project_help_is_scoped_and_exits_clean() {
  local out
  out="$(iw project -h 2>&1)"

  assert_ok "project -h succeeds" iw project -h
  assert_contains "lists a read verb" "iwork project show" "$out"
  assert_contains "lists a record verb" "iwork decided" "$out"
  assert_contains "lists the todo verb" "iwork todo" "$out"
  assert_contains "separates reading" "Reading" "$out"
  assert_contains "separates recording" "Recording" "$out"
  assert_contains "marks managing as the operator's" "the operator's" "$out"
  # Destructive task-level commands must not read as things to try.
  case "$out" in
    *"iwork rm "*) bad "project -h should not advertise 'iwork rm'" ;;
    *) ok ;;
  esac

  # No args behaves the same, and a typo points at the scoped help.
  assert_contains "bare 'project' prints help" "iwork project show" "$(iw project 2>&1)"
  assert_fails "unknown subcommand still fails" iw project frobnicate
  assert_contains "typo points at the scoped help" "iwork project -h" \
    "$(iw project frobnicate 2>&1)"
}

test_hook_names_the_scoped_help() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  local out
  out="$(hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionStart"}')"
  assert_contains "hook points at scoped help" "iwork project -h" "$out"
  assert_contains "hook draws the boundary" "the operator's" "$out"
}

# --- hooks --------------------------------------------------------------------

hook_fire() {
  local dir="$1"
  local json="$2"
  printf '%s' "$json" | iw_in "$dir" --hook 2>&1
}

test_hook_session_start_injects_brief() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" todo "needs backoff" >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" decided "cursor pagination" >/dev/null 2>&1

  local out
  out="$(hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionStart"}')"
  assert_contains "names the project" "myproj" "$out"
  assert_contains "carries the open todos" "needs backoff" "$out"
  assert_contains "carries the decisions" "cursor pagination" "$out"
  assert_contains "tells the agent how to write" "iwork decided" "$out"
  assert_contains "names the read commands" "iwork project show|grep|cat" "$out"
  assert_contains "forbids hand-writing, with the reason" "sibling tasks" "$out"
}

test_hook_session_start_works_from_a_worktree() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  mkdir -p "$SB_TASKS/feat-one/backend/src"

  local out
  out="$(hook_fire "$SB_TASKS/feat-one/backend/src" '{"hook_event_name":"SessionStart"}')"
  assert_contains "resolves the project from a nested cwd" "myproj" "$out"
}

test_hook_session_start_silent_when_irrelevant() {
  mk_repo backend
  iw feat/plain -r backend >/dev/null 2>&1

  # A task with no project, and a directory that is not a task at all: the hook
  # is installed globally, so both must produce nothing.
  assert_eq "silent for a task with no project" "" \
    "$(hook_fire "$SB_TASKS/feat-plain" '{"hook_event_name":"SessionStart"}')"
  assert_eq "silent outside any task" "" \
    "$(hook_fire "$SB" '{"hook_event_name":"SessionStart"}')"
  assert_eq "silent for an unknown event" "" \
    "$(hook_fire "$SB_TASKS/feat-plain" '{"hook_event_name":"Whatever"}')"
  assert_eq "silent for empty input" "" \
    "$(hook_fire "$SB_TASKS/feat-plain" '')"
}

test_hook_autologs_a_pr() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  local payload='{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"gh pr create --fill"},"tool_response":{"stdout":"https://github.com/acme/backend/pull/412\n"}}'
  local out
  out="$(hook_fire "$SB_TASKS/feat-one" "$payload")"

  assert_contains "hook reports what it recorded" "412" "$out"
  assert_grep "PR landed in the log" "acme/backend/pull/412" "$SB_PROJECTS/myproj/LOG.md"
  assert_grep "logged as shipped" "shipped:" "$SB_PROJECTS/myproj/LOG.md"

  # Same payload again must not duplicate the entry.
  hook_fire "$SB_TASKS/feat-one" "$payload" >/dev/null 2>&1
  assert_eq "PR logged exactly once" "1" \
    "$(grep -c 'pull/412' "$SB_PROJECTS/myproj/LOG.md")"
}

test_hook_ignores_bash_that_is_not_a_pr() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  hook_fire "$SB_TASKS/feat-one" \
    '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"}}' >/dev/null 2>&1
  # gh pr view mentions a URL but creates nothing.
  hook_fire "$SB_TASKS/feat-one" \
    '{"hook_event_name":"PostToolUse","tool_input":{"command":"gh pr view"},"tool_response":{"stdout":"https://github.com/acme/backend/pull/9"}}' >/dev/null 2>&1

  assert_eq "nothing logged" "0" \
    "$(grep -c '^- ' "$SB_PROJECTS/myproj/LOG.md")"
}

test_hook_precompact_prompts_a_flush() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  local out
  out="$(hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"PreCompact"}')"
  assert_contains "names the project" "myproj" "$out"
  assert_contains "offers the decided verb" "iwork decided" "$out"
  assert_contains "does not demand an entry" "record nothing" "$out"
  assert_eq "silent outside a project task" "" \
    "$(hook_fire "$SB" '{"hook_event_name":"PreCompact"}')"
}

test_hook_still_renames_tmux_windows() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  tmux_t new-session -d -s tasks -n feat-one -c "$SB_TASKS/feat-one" 2>/dev/null
  local pane socket
  pane="$(tmux_t list-panes -t tasks -F '#{pane_id}' 2>/dev/null | head -1)"
  socket="$(tmux_t display-message -p '#{socket_path}' 2>/dev/null)"
  if [[ -z "$pane" || -z "$socket" ]]; then
    printf '    skip (could not start isolated tmux server)\n'
    return 0
  fi

  # The restructured dispatcher must not have broken the original behaviour.
  printf '{"hook_event_name":"UserPromptSubmit"}' | env \
    TMUX="$socket,1,0" TMUX_PANE="$pane" TMUX_TMPDIR="$SB/tmux" \
    HOME="$SB_HOME" IWORK_CONFIG_FILE="$SB/config" \
    IWORK_REPO_DIR="$SB_REPOS" IWORK_TASKS_DIR="$SB_TASKS" \
    IWORK_PROJECTS_DIR="$SB_PROJECTS" \
    "$IWORK_SRC" --hook >/dev/null 2>&1

  assert_eq "busy marker still applied" "*feat-one" \
    "$(tmux_t display-message -p -t "$pane" '#{window_name}' 2>/dev/null)"
}

test_hook_marks_a_big_tasks_own_session() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  # The marker on a session *name* is opt-in; this is the test of that feature,
  # so it turns it on for every path it drives.
  local WANT_SESSION_MARKERS=on
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # A --big task owns the session, so the marker has to reach the session name:
  # the session list shows names and nothing else.
  tmux_t new-session -d -s tasks-feat-one -n feat-one -c "$SB_TASKS/feat-one" 2>/dev/null
  local pane socket
  pane="$(tmux_t list-panes -t tasks-feat-one -F '#{pane_id}' 2>/dev/null | head -1)"
  socket="$(tmux_t display-message -p '#{socket_path}' 2>/dev/null)"
  if [[ -z "$pane" || -z "$socket" ]]; then
    printf '    skip (could not start isolated tmux server)\n'
    return 0
  fi

  hook_in_pane() {
    printf '{"hook_event_name":"%s"}' "$1" | env \
      TMUX="$socket,1,0" TMUX_PANE="$pane" TMUX_TMPDIR="$SB/tmux" \
      HOME="$SB_HOME" IWORK_CONFIG_FILE="$SB/config" \
      IWORK_REPO_DIR="$SB_REPOS" IWORK_TASKS_DIR="$SB_TASKS" \
      IWORK_PROJECTS_DIR="$SB_PROJECTS" \
      IWORK_SESSION_MARKERS="${WANT_SESSION_MARKERS:-on}" \
      "$IWORK_SRC" --hook >/dev/null 2>&1
  }

  hook_in_pane UserPromptSubmit
  assert_eq "session marked busy" "*tasks-feat-one" \
    "$(tmux_t display-message -p -t "$pane" '#{session_name}' 2>/dev/null)"
  assert_eq "window marked busy too" "*feat-one" \
    "$(tmux_t display-message -p -t "$pane" '#{window_name}' 2>/dev/null)"

  hook_in_pane Stop
  assert_eq "session marked waiting" "!tasks-feat-one" \
    "$(tmux_t display-message -p -t "$pane" '#{session_name}' 2>/dev/null)"

  # And the marked name must not hide the task from anything that looks a
  # session up by name.
  # --big only because 'list' asks tmux for status when it does not need an
  # attached client, which the suite never has.
  assert_contains "list still sees the dedicated session" "!waiting (session)" \
    "$(WANT_TMUX=1 iw --big list 2>&1)"

  WANT_TMUX=1 iw rm -f feat-one >/dev/null 2>&1
  if tmux_t list-sessions -F '#{session_name}' 2>/dev/null | grep -q 'tasks-feat-one'; then
    bad "rm left the marked session behind"
  else
    ok
  fi
  unset -f hook_in_pane
}

test_hook_marks_the_shared_session_from_its_windows() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  # The marker on a session *name* is opt-in; this is the test of that feature,
  # so it turns it on for every path it drives.
  local WANT_SESSION_MARKERS=on
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw feat/two -r backend -p myproj >/dev/null 2>&1

  tmux_t new-session -d -s tasks -n feat-one -c "$SB_TASKS/feat-one" 2>/dev/null
  tmux_t new-window -d -t '=tasks' -n feat-two -c "$SB_TASKS/feat-two" 2>/dev/null
  local one two socket
  one="$(tmux_t list-panes -t '=tasks:feat-one' -F '#{pane_id}' 2>/dev/null | head -1)"
  two="$(tmux_t list-panes -t '=tasks:feat-two' -F '#{pane_id}' 2>/dev/null | head -1)"
  socket="$(tmux_t display-message -p '#{socket_path}' 2>/dev/null)"
  if [[ -z "$one" || -z "$two" || -z "$socket" ]]; then
    printf '    skip (could not start isolated tmux server)\n'
    return 0
  fi

  hook_in_pane() {
    printf '{"hook_event_name":"%s"}' "$2" | env \
      TMUX="$socket,1,0" TMUX_PANE="$1" TMUX_TMPDIR="$SB/tmux" \
      HOME="$SB_HOME" IWORK_CONFIG_FILE="$SB/config" \
      IWORK_REPO_DIR="$SB_REPOS" IWORK_TASKS_DIR="$SB_TASKS" \
      IWORK_PROJECTS_DIR="$SB_PROJECTS" \
      IWORK_SESSION_MARKERS="${WANT_SESSION_MARKERS:-on}" \
      "$IWORK_SRC" --hook >/dev/null 2>&1
  }
  shared_name() { tmux_t list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^[*!]?tasks$'; }

  hook_in_pane "$one" UserPromptSubmit
  assert_eq "one agent working marks the session busy" "*tasks" "$(shared_name)"

  # Waiting outranks working: the session has to report the agent that cannot
  # move without you, not the one that is fine.
  hook_in_pane "$two" Stop
  assert_eq "one waiting agent wins over a working one" "!tasks" "$(shared_name)"

  hook_in_pane "$two" UserPromptSubmit
  assert_eq "and it drops back when nobody waits" "*tasks" "$(shared_name)"

  # Derived, not sticky: closing the last waiting window has to clear it.
  hook_in_pane "$two" Stop
  assert_eq "waiting again" "!tasks" "$(shared_name)"
  WANT_TMUX=1 iw rm -f feat-two >/dev/null 2>&1
  assert_eq "rm of the waiting task refreshes the session" "*tasks" "$(shared_name)"

  # And the marked name must not send iwork off to build a second session.
  iw feat/three -r backend >/dev/null 2>&1
  WANT_TMUX=1 iw --detach claude feat-three >/dev/null 2>&1
  assert_eq "no second shared session was created" "1" "$(shared_name | grep -c .)"
  assert_contains "the new window landed in the marked session" "feat-three" \
    "$(tmux_t list-windows -t "=$(shared_name)" -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"

  unset -f hook_in_pane shared_name
}

test_install_hooks_registers_every_event() {
  command -v python3 >/dev/null 2>&1 || { printf '    skip (no python3)\n'; return 0; }
  iw install-hooks "$SB/settings.json" >/dev/null 2>&1

  assert_file "settings written" "$SB/settings.json"
  assert_eq "every event registered" "" "$(python3 - "$SB/settings.json" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1])).get("hooks", {})
want = ["UserPromptSubmit", "Stop", "Notification", "SessionStart", "SessionEnd", "PreCompact", "PostToolUse"]
print(",".join(e for e in want if not hooks.get(e)), end="")
PY
)"
  assert_eq "PostToolUse is scoped to Bash" "Bash" "$(python3 - "$SB/settings.json" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1])).get("hooks", {})
print("".join(e.get("matcher", "") for e in hooks.get("PostToolUse", [])), end="")
PY
)"

  # Re-running must not duplicate anything.
  iw install-hooks "$SB/settings.json" >/dev/null 2>&1
  local count
  count="$(python3 - "$SB/settings.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(sum(len(v) for v in data.get("hooks", {}).values()))
PY
)"
  assert_eq "install-hooks is idempotent" "7" "$count"
}

# --- review findings: durability ----------------------------------------------

test_todo_ids_are_wide_enough_to_not_collide() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # 16-bit ids collided at a couple of hundred todos, and a collision made both
  # entries permanently unclosable. Check the width, then check a realistic
  # volume actually stays unique.
  iw_in "$SB_TASKS/feat-one" todo "width probe" >/dev/null 2>&1
  local id
  id="$(sed -n 's/.*(\(t[0-9a-f]*\)).*/\1/p' "$SB_PROJECTS/myproj/TODO.md" | head -1)"
  assert_eq "id is 8 hex digits" "9" "${#id}"

  local i
  for i in $(seq 1 200); do
    printf -- '- [ ] (%s) filler %s — from feat-one, 2026-08-21\n' \
      "$(iw_in "$SB_TASKS/feat-one" todo "item $i" | sed -n 's/^Captured \(t[0-9a-f]*\).*/\1/p')" \
      "$i" >/dev/null
  done
  local total unique
  total="$(grep -c '^- \[' "$SB_PROJECTS/myproj/TODO.md")"
  unique="$(grep -o '(t[0-9a-f]*)' "$SB_PROJECTS/myproj/TODO.md" | sort -u | wc -l | tr -d ' ')"
  assert_eq "no id collisions across 201 todos" "$total" "$unique"
}

test_ambiguous_todo_id_is_recoverable() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  # Hand-craft the collision that a 16-bit id used to produce, and check there
  # is a way out. Previously both entries were unclosable forever.
  {
    printf -- '- [ ] (tdeadbeef) first colliding item — from feat-one, 2026-08-21\n'
    printf -- '- [ ] (tdeadbeef) second colliding item — from feat-one, 2026-08-21\n'
  } >> "$SB_PROJECTS/myproj/TODO.md"

  local out
  out="$(iw_in "$SB_TASKS/feat-one" "done" tdeadbeef 2>&1)"
  assert_contains "ambiguity lists the candidates" "first colliding item" "$out"
  assert_contains "ambiguity offers --nth" "--nth" "$out"

  assert_ok "--nth closes the chosen one" \
    iw_in "$SB_TASKS/feat-one" "done" tdeadbeef --nth 2
  assert_grep "second is closed" '\[x\].*second colliding item' "$SB_PROJECTS/myproj/TODO.md"
  assert_grep "first left alone" '\[ \].*first colliding item' "$SB_PROJECTS/myproj/TODO.md"
  assert_fails "--nth out of range refused" \
    iw_in "$SB_TASKS/feat-one" "done" tdeadbeef --nth 9
}

test_captured_text_is_length_capped() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  local huge
  huge="$(head -c 5000 /dev/zero | tr '\0' 'x')"
  iw_in "$SB_TASKS/feat-one" decided "$huge" >/dev/null 2>&1

  local longest
  longest="$(awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' \
    "$SB_PROJECTS/myproj/LOG.md")"
  # An uncapped entry would be injected into every future session forever.
  if (( longest < 1200 )); then ok; else bad "log line not capped (longest $longest chars)"; fi
  assert_grep "truncation is visible" "truncated" "$SB_PROJECTS/myproj/LOG.md"
}

test_hook_exits_zero_when_it_cannot_write() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  chmod 500 "$SB_PROJECTS/myproj"

  # append_log used to die(), which exits past every '|| true' the hook wrapped
  # it in, so Claude Code saw a failing hook with empty stderr.
  local payload='{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"gh pr create --fill"},"tool_response":{"stdout":"https://github.com/acme/backend/pull/5\n"}}'
  printf '%s' "$payload" | iw_in "$SB_TASKS/feat-one" --hook >/dev/null 2>&1
  assert_eq "PostToolUse exits 0 even when the log is unwritable" "0" "$?"

  printf '{"hook_event_name":"SessionStart"}' | iw_in "$SB_TASKS/feat-one" --hook >/dev/null 2>&1
  assert_eq "SessionStart exits 0 too" "0" "$?"
  chmod 700 "$SB_PROJECTS/myproj"
}

test_bad_show_log_lines_does_not_break_the_brief() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" decided "a decision worth seeing" >/dev/null 2>&1

  # Evaluated inside (( )) and by tail -n, so a non-numeric value used to abort
  # project_show halfway and take the hook's exit status with it.
  local out
  out="$(WANT_SHOW_LINES=lots iw project show myproj 2>/dev/null)"
  assert_eq "project show still succeeds" "0" "$?"
  assert_contains "and is complete" "a decision worth seeing" "$out"

  out="$(printf '{"hook_event_name":"SessionStart"}' |
    WANT_SHOW_LINES=lots iw_in "$SB_TASKS/feat-one" --hook 2>/dev/null)"
  assert_eq "SessionStart hook still exits 0" "0" "$?"
  assert_contains "and injects the whole brief" "a decision worth seeing" "$out"
}

test_pr_autolog_ignores_mentions_of_the_command() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # A substring test over the whole payload logged PR links that appeared in
  # tool OUTPUT, e.g. grepping the docs for "gh pr create".
  local grepping='{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"grep -rn \"gh pr create\" docs/"},"tool_response":{"stdout":"docs/x.md:4: see https://github.com/acme/backend/pull/9001\n"}}'
  printf '%s' "$grepping" | iw_in "$SB_TASKS/feat-one" --hook >/dev/null 2>&1
  assert_no_grep "a grep for the command logs nothing" "9001" "$SB_PROJECTS/myproj/LOG.md"

  local reading='{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"cat CONTRIBUTING.md"},"tool_response":{"stdout":"Run gh pr create. See https://github.com/acme/backend/pull/1\n"}}'
  printf '%s' "$reading" | iw_in "$SB_TASKS/feat-one" --hook >/dev/null 2>&1
  assert_no_grep "reading a file that mentions it logs nothing" "pull/1" \
    "$SB_PROJECTS/myproj/LOG.md"

  # ...but a real invocation still lands, including behind a cd chain.
  local real='{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"cd backend && gh pr create --fill"},"tool_response":{"stdout":"https://github.com/acme/backend/pull/77\n"}}'
  printf '%s' "$real" | iw_in "$SB_TASKS/feat-one" --hook >/dev/null 2>&1
  assert_grep "a real gh pr create is still logged" "pull/77" "$SB_PROJECTS/myproj/LOG.md"
}

test_project_link_beats_the_env_var() {
  mk_repo backend
  mk_repo frontend
  iw feat/one -r backend -p alpha >/dev/null 2>&1
  iw feat/two -r frontend -p beta >/dev/null 2>&1

  # Exporting IWORK_PROJECT once used to misfile every capture from every other
  # project's tasks, silently.
  WANT_PROJECT_ENV=beta iw_in "$SB_TASKS/feat-one" todo "belongs to alpha" >/dev/null 2>&1
  assert_grep "capture went to the task's own project" "belongs to alpha" \
    "$SB_PROJECTS/alpha/TODO.md"
  assert_no_grep "and not to the env var's project" "belongs to alpha" \
    "$SB_PROJECTS/beta/TODO.md"

  # Outside a task it is still the fallback, and -p still wins everywhere.
  WANT_PROJECT_ENV=beta iw_in "$SB" todo "outside any task" >/dev/null 2>&1
  assert_grep "env var applies outside a task" "outside any task" "$SB_PROJECTS/beta/TODO.md"
  WANT_PROJECT_ENV=beta iw_in "$SB_TASKS/feat-one" todo "explicit wins" -p beta >/dev/null 2>&1
  assert_grep "-p overrides both" "explicit wins" "$SB_PROJECTS/beta/TODO.md"
}

# --- review findings: correctness ---------------------------------------------

test_project_cat_refuses_a_symlink_out() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  echo "SECRET" > "$SB/outside.txt"
  ln -s "$SB/outside.txt" "$SB_PROJECTS/myproj/notes/link.md"
  ln -s /etc "$SB_PROJECTS/myproj/notes/etc"

  # The '..' check was not containment: a symlink inside the project reached
  # outside it without one.
  assert_fails "symlinked file refused" \
    iw_in "$SB_TASKS/feat-one" project cat notes/link.md
  assert_fails "symlinked directory refused" \
    iw_in "$SB_TASKS/feat-one" project cat notes/etc/hosts
  assert_ok "a real file inside is still readable" \
    iw_in "$SB_TASKS/feat-one" project cat LOG.md
}

test_park_validates_the_task_before_creating_a_project() {
  mk_repo backend
  git -C "$SB_REPOS/backend" checkout -q -b feat/parked
  ( cd "$SB_REPOS/backend" && iw park 'bad/name' -p brandnew ) >/dev/null 2>&1
  assert_no_file "no stray project from an invalid task name" "$SB_PROJECTS/brandnew"
}

test_park_refuses_a_repo_outside_the_repo_dir() {
  mk_repo backend
  git init -q -b main "$SB/elsewhere"
  ( cd "$SB/elsewhere" && git -c user.name=t -c user.email=t@e commit -qm init --allow-empty
    git checkout -q -b feat/x ) >/dev/null 2>&1
  assert_fails "park refuses a repo outside IWORK_REPO_DIR" \
    sh -c "cd '$SB/elsewhere' && '$IWORK_SRC' park sometask"
}

test_project_show_accepts_the_p_flag() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  # Both help texts advertise this; only the positional form worked.
  assert_ok "project show -p works" iw project show -p myproj
  assert_contains "and targets the right project" "myproj" \
    "$(iw project show -p myproj 2>&1)"
}

test_detach_is_recorded_in_history() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw project rm myproj feat-one >/dev/null 2>&1

  assert_grep "detach recorded" "detached" "$SB_PROJECTS/myproj/history.tsv"
  rm -rf "$SB_TASKS/feat-one"
  local out
  out="$(iw project show myproj 2>&1)"
  # Without the detach event the task showed as 'opened' forever.
  assert_contains "past tasks show the detach" "detached" "$out"
}

test_done_and_drop_reject_kind_flags() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" todo "a thing" >/dev/null 2>&1
  local id
  id="$(sed -n 's/.*(\(t[0-9a-f]*\)).*/\1/p' "$SB_PROJECTS/myproj/TODO.md" | head -1)"

  # These were silently accepted and ignored.
  assert_fails "done rejects --shipped" iw_in "$SB_TASKS/feat-one" "done" "$id" --shipped
  assert_fails "drop rejects --decision" iw_in "$SB_TASKS/feat-one" drop "$id" --decision
  assert_grep "todo untouched" '^- \[ \]' "$SB_PROJECTS/myproj/TODO.md"
}

test_misplaced_flag_after_repos_is_an_error() {
  mk_repo backend
  # Used to surface as ".../-p is not a git repository".
  local out

  # Flags read in any position on an add-repo line now, so this one is legal and
  # the command gets as far as its real complaint instead of taking the flag for
  # a repo name.
  out="$(iw add-repo nosuchtask -r backend --from main 2>&1 || true)"
  assert_contains "a flag after -r is parsed as a flag" "worktree folder not found" "$out"

  # -p is not add-repo's to take, and is refused rather than quietly ignored.
  out="$(iw add-repo nosuchtask -r backend -p proj 2>&1 || true)"
  assert_contains "-p on add-repo says where it does belong" "does not apply to add-repo" "$out"

  # rm still gathers repos with the stricter parser, where a trailing flag is
  # a mistake rather than a position.
  out="$(iw rm -f nosuchtask -r backend -p proj 2>&1 || true)"
  assert_contains "same for rm" "unexpected option" "$out"
}

test_install_hooks_quotes_the_command_path() {
  command -v python3 >/dev/null 2>&1 || { printf '    skip (no python3)\n'; return 0; }
  mkdir -p "$SB/my tools"
  cp "$IWORK_SRC" "$SB/my tools/iwork"
  chmod +x "$SB/my tools/iwork"

  env -u TMUX HOME="$SB_HOME" IWORK_CONFIG_FILE="$SB/config" \
    IWORK_REPO_DIR="$SB_REPOS" IWORK_TASKS_DIR="$SB_TASKS" \
    IWORK_PROJECTS_DIR="$SB_PROJECTS" IWORK_ASSUME_YES=1 \
    "$SB/my tools/iwork" install-hooks "$SB/settings-spaces.json" >/dev/null 2>&1

  # An unquoted path made every hook fail with 127.
  local cmd
  cmd="$(python3 - "$SB/settings-spaces.json" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1])).get("hooks", {})
for entries in hooks.values():
    for e in entries:
        for h in e.get("hooks", []):
            print(h.get("command", "")); raise SystemExit
PY
)"
  assert_contains "path is quoted or escaped" '\' "$cmd"
  assert_ok "and the quoted command actually runs" \
    sh -c "printf '{\"hook_event_name\":\"Stop\"}' | $cmd"
}

# --- review findings: the four mutations that survived -------------------------

test_project_delete_requires_force_for_real() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" decided "worth keeping" >/dev/null 2>&1
  iw project rm myproj feat-one >/dev/null 2>&1

  # The old test passed because a task was still attached, so it never
  # exercised the -f requirement at all.
  assert_fails "delete without -f is refused" iw project delete myproj
  assert_dir "project survives the refusal" "$SB_PROJECTS/myproj"
  assert_grep "memory intact" "worth keeping" "$SB_PROJECTS/myproj/LOG.md"

  assert_ok "delete -f removes it" iw project delete -f myproj
  assert_no_file "project is gone" "$SB_PROJECTS/myproj"
}

test_project_delete_refuses_while_attached_even_with_force() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  assert_fails "attached task blocks delete even with -f" iw project delete -f myproj
  assert_dir "project survives" "$SB_PROJECTS/myproj"
}

test_flip_todo_takes_the_lock() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw_in "$SB_TASKS/feat-one" todo "a thing" >/dev/null 2>&1
  local id
  id="$(sed -n 's/.*(\(t[0-9a-f]*\)).*/\1/p' "$SB_PROJECTS/myproj/TODO.md" | head -1)"

  # A live lock held by this very shell must block the rewrite. Without this,
  # removing the lock entirely from flip_todo went unnoticed.
  mkdir -p "$SB_PROJECTS/myproj/.lock"
  echo "$$" > "$SB_PROJECTS/myproj/.lock/pid"
  assert_fails "flip refuses while the lock is genuinely held" \
    iw_in "$SB_TASKS/feat-one" "done" "$id"
  assert_grep "todo untouched" '^- \[ \]' "$SB_PROJECTS/myproj/TODO.md"
  rm -rf "$SB_PROJECTS/myproj/.lock"

  assert_ok "and succeeds once released" iw_in "$SB_TASKS/feat-one" "done" "$id"
}

# --- review findings: tmux, which nothing exercised ---------------------------

test_tmux_window_is_created_for_a_task() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend

  # WANT_TMUX was dead, so window creation, session naming and kill_task_tmux
  # were never run by any test.
  WANT_TMUX=1 iw --detach feat/loose -r backend >/dev/null 2>&1

  local windows
  windows="$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
  assert_contains "a window was created for the task" "feat-loose" "$windows"
  assert_no_file "and it joined no project" "$SB_TASKS/feat-loose/.project"
}

test_a_projects_task_goes_to_the_projects_session() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend

  # The shared session is for tasks that belong to nobody. A task with a project
  # goes to that project's session, whoever created it — the operator here.
  WANT_TMUX=1 iw --detach feat/one -r backend -p myproj >/dev/null 2>&1
  WANT_TMUX=1 iw --detach feat/loose -r backend >/dev/null 2>&1

  assert_contains "the project's task landed in the project session" "feat-one" \
    "$(tmux_t list-windows -t '=projects-myproj' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
  assert_link "and it is attached" "$SB_TASKS/feat-one/.project"

  local shared
  shared="$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
  assert_contains "the loose task is in the shared session" "feat-loose" "$shared"
  case "$shared" in
    *feat-one*) bad "a project's task cluttered the shared session" ;;
    *) ok ;;
  esac

  # Every lookup has to follow it there, or 'cd', 'list' and 'rm' stop seeing it.
  assert_contains "list reports its agent state" "feat-one" \
    "$(WANT_TMUX=1 iw --big list 2>&1)"
  WANT_TMUX=1 iw rm -f feat-one >/dev/null 2>&1
  case "$(tmux_t list-windows -t '=projects-myproj' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')" in
    *feat-one*) bad "rm left the task's window in the project session" ;;
    *) ok ;;
  esac
}

test_tmux_session_is_killed_with_the_task() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach --big feat/one -r backend -p myproj >/dev/null 2>&1

  local session="tasks-feat-one"
  if ! tmux_t has-session -t "=$session" 2>/dev/null; then
    printf '    skip (--big session not created in this environment)\n'
    return 0
  fi
  ok
  WANT_TMUX=1 iw rm -f feat-one >/dev/null 2>&1
  if tmux_t has-session -t "=$session" 2>/dev/null; then
    bad "rm left the task's tmux session behind"
  else
    ok
  fi
  assert_dir "project memory survived" "$SB_PROJECTS/myproj"
}

test_project_names_differing_only_by_case() {
  mk_repo backend
  mk_repo frontend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # On a case-insensitive filesystem these are one directory, so 'MyProj' must
  # resolve to the existing project rather than becoming a second name sharing
  # its files.
  iw feat/two -r frontend -p MyProj >/dev/null 2>&1
  local linked
  linked="$(basename "$(cd "$SB_TASKS/feat-two/.project" && pwd -P)")"
  assert_eq "second task linked to the existing spelling" "myproj" "$linked"

  local out
  out="$(iw project show myproj 2>&1)"
  assert_contains "first task listed as live" "feat-one" "$out"
  assert_contains "second task listed as live too" "feat-two" "$out"

  iw_in "$SB_TASKS/feat-two" todo "captured via the other spelling" >/dev/null 2>&1
  assert_grep "capture landed in the one project" "captured via the other spelling" \
    "$SB_PROJECTS/myproj/TODO.md"
}

test_install_hooks_refuses_malformed_settings() {
  command -v python3 >/dev/null 2>&1 || { printf '    skip (no python3)\n'; return 0; }
  printf '%s\n' '{ this is not json' > "$SB/bad-settings.json"

  local out
  out="$(iw install-hooks "$SB/bad-settings.json" 2>&1 || true)"
  assert_contains "says the file is the problem" "not valid JSON" "$out"
  case "$out" in
    *Traceback*) bad "install-hooks should not print a Python traceback" ;;
    *) ok ;;
  esac
  assert_grep "the broken file is left untouched" "this is not json" "$SB/bad-settings.json"
}

# --- current-task inference ----------------------------------------------------

test_project_add_infers_the_current_task() {
  mk_repo backend
  iw feat/oops -r backend >/dev/null 2>&1

  # From the task root, and from a nested worktree directory.
  iw_in "$SB_TASKS/feat-oops" project add token-work >/dev/null 2>&1
  assert_link "attached without naming the task" "$SB_TASKS/feat-oops/.project"

  iw feat/other -r backend >/dev/null 2>&1 || true
  mkdir -p "$SB_TASKS/feat-other/backend/src/deep"
  iw_in "$SB_TASKS/feat-other/backend/src/deep" project add token-work >/dev/null 2>&1
  assert_link "works from deep inside a worktree" "$SB_TASKS/feat-other/.project"

  # An explicit name still wins over the current directory.
  iw feat/third -r backend >/dev/null 2>&1 || true
  iw_in "$SB_TASKS/feat-oops" project add token-work feat-third >/dev/null 2>&1
  assert_link "explicit name overrides the cwd" "$SB_TASKS/feat-third/.project"
}

test_project_rm_infers_both_project_and_task() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # The task from the directory, the project from its own .project link.
  iw_in "$SB_TASKS/feat-one" project rm >/dev/null 2>&1
  assert_no_file "detached with no arguments at all" "$SB_TASKS/feat-one/.project"
  assert_dir "memory kept" "$SB_PROJECTS/myproj"
  assert_fails "and a second bare rm has nothing to detach" \
    iw_in "$SB_TASKS/feat-one" project rm
}

test_add_repo_infers_the_current_task() {
  mk_repo backend
  mk_repo frontend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  iw_in "$SB_TASKS/feat-one" add-repo -r frontend >/dev/null 2>&1
  assert_dir "worktree added without naming the task" "$SB_TASKS/feat-one/frontend"
  assert_grep "repos block still refreshed" "frontend" "$SB_TASKS/feat-one/CLAUDE.md"
}

test_add_repo_infers_the_task_before_from() {
  mk_repo backend
  mk_repo frontend
  iw feat/base -r frontend >/dev/null 2>&1
  ( cd "$SB_TASKS/feat-base/frontend" && echo base > base.txt &&
    git add -A && git commit -qm base )
  iw feat/one -r backend >/dev/null 2>&1

  # --from is a leading flag here, so the task must still be inferred.
  iw_in "$SB_TASKS/feat-one" add-repo --from feat-base -r frontend >/dev/null 2>&1
  assert_file "inferred task and honoured --from" "$SB_TASKS/feat-one/frontend/base.txt"
}

test_rm_requires_current_to_be_explicit() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # A bare 'iwork rm' inside a task must not mean "delete this".
  local out
  out="$(iw_in "$SB_TASKS/feat-one" rm -f 2>&1 || true)"
  assert_contains "bare rm explains itself" "--current" "$out"
  assert_dir "task untouched" "$SB_TASKS/feat-one"

  assert_fails "name and --current together are refused" \
    iw_in "$SB_TASKS/feat-one" rm -f --current feat-one

  iw_in "$SB_TASKS/feat-one" rm -f --current >/dev/null 2>&1
  assert_no_file "--current removes the task you are in" "$SB_TASKS/feat-one"
  assert_dir "project memory survives" "$SB_PROJECTS/myproj"
}

test_inference_fails_clearly_outside_a_task() {
  mk_repo backend
  local out
  out="$(iw_in "$SB" project add someproject 2>&1 || true)"
  assert_contains "says there is no current task" "no current task" "$out"
  assert_no_file "and creates nothing" "$SB_PROJECTS/someproject"

  out="$(iw_in "$SB" add-repo -r backend 2>&1 || true)"
  assert_contains "add-repo says the same" "no current task" "$out"
  out="$(iw_in "$SB" rm -f --current 2>&1 || true)"
  assert_contains "rm --current says the same" "no current task" "$out"
}

# --- agent registry -----------------------------------------------------------

test_agents_register_on_session_start() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  local WANT_SESSION_ID="sess-aaa" WANT_CLAUDE_PID="$$" WANT_PANE="%42"

  hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionStart"}' >/dev/null

  assert_file "agents.tsv is written" "$SB_PROJECTS/myproj/agents.tsv"
  assert_grep "the session is recorded against its task" \
    "registered[[:space:]]feat-one[[:space:]]sess-aaa" "$SB_PROJECTS/myproj/agents.tsv"
  # The pane, not the session id, is what the master can turn into an address.
  assert_grep "the pane is recorded too" "%42" "$SB_PROJECTS/myproj/agents.tsv"

  local out
  out="$(iw_in "$SB_TASKS/feat-one" project agents 2>&1)"
  assert_contains "project agents names the session" "sess-aaa" "$out"
  assert_contains "and the task it is in" "feat-one" "$out"
  assert_contains "and the pane" "%42" "$out"
}

test_agents_deregister_on_session_end() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  local WANT_SESSION_ID="sess-bbb" WANT_CLAUDE_PID="$$" WANT_PANE="%7"

  hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionStart"}' >/dev/null
  assert_contains "live to begin with" "sess-bbb" \
    "$(iw_in "$SB_TASKS/feat-one" project agents 2>&1)"

  hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionEnd"}' >/dev/null
  assert_contains "gone after SessionEnd" "(none)" \
    "$(iw_in "$SB_TASKS/feat-one" project agents 2>&1)"
  # Append-only: leaving is a new row, not the removal of an old one.
  assert_grep "both events survive on disk" "ended" "$SB_PROJECTS/myproj/agents.tsv"
  assert_grep "including the registration" "registered" "$SB_PROJECTS/myproj/agents.tsv"
}

test_agents_drops_a_session_that_died() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # A session that went away without a SessionEnd: a killed pane, a crash,
  # kill -9. Nothing will ever write an 'ended' row for it.
  ( exit 0 ) &
  local dead=$!
  wait "$dead" 2>/dev/null || true

  local WANT_SESSION_ID="sess-ccc" WANT_CLAUDE_PID="$dead" WANT_PANE="%9"
  hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionStart"}' >/dev/null

  assert_grep "the row is still on disk" "sess-ccc" "$SB_PROJECTS/myproj/agents.tsv"
  assert_contains "but liveness is derived, so it is not listed" "(none)" \
    "$(iw_in "$SB_TASKS/feat-one" project agents 2>&1)"
}

test_agents_two_sessions_in_one_task() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # One task can hold several agents, so the map is task -> many.
  local WANT_CLAUDE_PID="$$"
  local WANT_SESSION_ID="sess-one" WANT_PANE="%1"
  hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionStart"}' >/dev/null
  WANT_SESSION_ID="sess-two"
  WANT_PANE="%2"
  hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionStart"}' >/dev/null

  local out
  out="$(iw_in "$SB_TASKS/feat-one" project agents 2>&1)"
  assert_contains "the first is listed" "sess-one" "$out"
  assert_contains "the second is listed too" "sess-two" "$out"

  out="$(iw_in "$SB_TASKS/feat-one" project show 2>&1)"
  assert_contains "project show counts them on the task" "2 agents" "$out"
}

test_agents_a_resumed_session_is_listed_once() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  local WANT_SESSION_ID="sess-ddd" WANT_CLAUDE_PID="$$" WANT_PANE="%5"

  # SessionStart fires again on resume and on compaction, so the same session
  # registers repeatedly. It must still be one agent, not three.
  hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionStart"}' >/dev/null
  hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionStart"}' >/dev/null
  hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionStart"}' >/dev/null

  assert_eq "listed once despite three registrations" "1" \
    "$(iw_in "$SB_TASKS/feat-one" project agents 2>&1 | grep -c 'sess-ddd')"
  assert_contains "and counted once" "1 agent" \
    "$(iw_in "$SB_TASKS/feat-one" project show 2>&1)"
}

test_agents_last_active_comes_from_the_transcript() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  : > "$SB/transcript.jsonl"
  local WANT_SESSION_ID="sess-fff" WANT_CLAUDE_PID="$$" WANT_PANE="%3"

  hook_fire "$SB_TASKS/feat-one" \
    "{\"hook_event_name\":\"SessionStart\",\"transcript_path\":\"$SB/transcript.jsonl\"}" >/dev/null

  assert_grep "the transcript path is recorded" "transcript.jsonl" \
    "$SB_PROJECTS/myproj/agents.tsv"
  assert_contains "and reported as an age, derived on read" "last active" \
    "$(iw_in "$SB_TASKS/feat-one" project agents 2>&1)"
}

test_agents_without_a_session_id_registers_nothing() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # WANT_SESSION_ID unset, so CLAUDE_CODE_SESSION_ID is empty: a plain shell
  # running the hook, not a Claude session.
  local out
  out="$(hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionStart"}')"
  assert_contains "the brief is still injected" "myproj" "$out"
  assert_contains "but nobody is registered" "(none)" \
    "$(iw_in "$SB_TASKS/feat-one" project agents 2>&1)"
}

test_agents_registration_is_silent_outside_a_project() {
  mk_repo backend
  iw feat/plain -r backend >/dev/null 2>&1
  local WANT_SESSION_ID="sess-ggg" WANT_CLAUDE_PID="$$"

  assert_eq "SessionStart says nothing for a task with no project" "" \
    "$(hook_fire "$SB_TASKS/feat-plain" '{"hook_event_name":"SessionStart"}')"
  assert_eq "nor does SessionEnd" "" \
    "$(hook_fire "$SB_TASKS/feat-plain" '{"hook_event_name":"SessionEnd"}')"
  assert_eq "nor either of them outside a task at all" "" \
    "$(hook_fire "$SB" '{"hook_event_name":"SessionEnd"}')"
}

test_agents_tsv_appears_for_a_project_that_predates_it() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # Projects created before this feature have no agents.tsv, and there is no
  # migration step — the first registration has to grow the file itself.
  rm -f "$SB_PROJECTS/myproj/agents.tsv"
  local WANT_SESSION_ID="sess-hhh" WANT_CLAUDE_PID="$$" WANT_PANE="%8"
  hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionStart"}' >/dev/null

  assert_file "the file is recreated" "$SB_PROJECTS/myproj/agents.tsv"
  assert_grep "with its header" "^# timestamp" "$SB_PROJECTS/myproj/agents.tsv"
  assert_contains "and the session is listed" "sess-hhh" \
    "$(iw_in "$SB_TASKS/feat-one" project agents 2>&1)"
}

test_agents_row_without_a_pid_or_pane_still_lists() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # A harness that exports no pid, or a row written before one was recorded.
  # There is nothing to signal, so the 'ended' event is the only thing that can
  # retire it — and the display must not choke on the empty columns.
  printf '2026-01-01T00:00:00+0000\tregistered\tfeat-one\tsess-old\t\t\t\n' \
    >> "$SB_PROJECTS/myproj/agents.tsv"

  local out
  out="$(iw_in "$SB_TASKS/feat-one" project agents 2>&1)"
  assert_contains "listed despite the empty columns" "sess-old" "$out"
  assert_contains "under its task" "feat-one" "$out"
  assert_contains "and counted by project show" "1 agent" \
    "$(iw_in "$SB_TASKS/feat-one" project show 2>&1)"

  local WANT_SESSION_ID="sess-old" WANT_CLAUDE_PID="$$"
  hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionEnd"}' >/dev/null
  assert_contains "and an 'ended' row still retires it" "(none)" \
    "$(iw_in "$SB_TASKS/feat-one" project agents 2>&1)"
}

test_agents_verb_rejects_junk_and_resolves_a_project() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  assert_fails "an unknown flag is refused" iw project agents --nope
  assert_fails "two projects are refused" iw project agents myproj otherproj
  assert_ok "a positional project works from anywhere" iw project agents myproj
  assert_ok "so does -p" iw project agents -p myproj
  assert_fails "an unknown project still fails" iw project agents nosuchproject
}

test_read_verbs_work_from_the_project_directory() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  local WANT_SESSION_ID="sess-iii" WANT_CLAUDE_PID="$$" WANT_PANE="%4"
  hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionStart"}' >/dev/null
  unset WANT_SESSION_ID WANT_CLAUDE_PID WANT_PANE

  # The project directory is where a session coordinating the other tasks runs,
  # and it used to be the one place the read verbs could not infer a project.
  local out
  out="$(iw_in "$SB_PROJECTS/myproj" project agents 2>&1)"
  assert_contains "the project is inferred from the directory" "myproj" "$out"
  assert_contains "and the task's agents are listed" "sess-iii" "$out"

  assert_ok "show works there too" iw_in "$SB_PROJECTS/myproj" project show
  assert_ok "and from a subdirectory of it" iw_in "$SB_PROJECTS/myproj/notes" project show

  out="$(iw_in "$SB" project agents 2>&1 || true)"
  assert_contains "outside both kinds of directory it still says how to say which" \
    "pass -p" "$out"
}

test_project_directory_beats_the_env_var() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  mkdir -p "$SB_PROJECTS/otherproj"

  # Same reasoning as the .project link beating it: an IWORK_PROJECT exported
  # once in a shell profile must not silently redirect what you are standing in.
  local WANT_PROJECT_ENV="otherproj"
  assert_contains "the directory wins over IWORK_PROJECT" "myproj" \
    "$(iw_in "$SB_PROJECTS/myproj" project agents 2>&1)"
}

test_project_flag_and_message_coexist() {
  mk_repo backend

  # -m arrived on main while -p was on this branch; both parse in any position
  # and neither swallows the other's value.
  local out
  out="$(iw feat/one -r backend -m "start on the refactor" -p myproj 2>&1)"
  assert_link "the task still joined the project" "$SB_TASKS/feat-one/.project"
  assert_grep "and got its project block" "iwork:project" "$SB_TASKS/feat-one/CLAUDE.md"
  assert_contains "-m says it could not be delivered without tmux" "-m was not delivered" "$out"

  out="$(iw -m "another" feat/two -r backend -p myproj 2>&1)"
  assert_link "-m ahead of the branch name works too" "$SB_TASKS/feat-two/.project"
}

test_message_undelivered_on_project_subcommands() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # These start no agent either, and main's list predates them: a dropped
  # message must still be reported rather than silently discarded.
  local verb out
  for verb in "project list" "todo something" "decided something"; do
    # shellcheck disable=SC2086
    out="$(iw -m "hi" $verb 2>&1)"
    assert_contains "-m reports itself undelivered for '$verb'" "-m was not delivered" "$out"
  done
}

# The pre-marker template, as anyone who used iwork before the marker blocks
# existed still has on disk.
write_old_template() {
  cat > "$SB_HOME/.config/iwork/task-context.md.tmpl" <<'TMPL'
# Task: {{TASK}}

My own note, which must survive.

{{REPOS}}

## Scope

- Stay within this task directory.
TMPL
}

test_old_context_template_gains_the_repos_markers() {
  mk_repo backend
  mk_repo frontend
  write_old_template

  local tmpl="$SB_HOME/.config/iwork/task-context.md.tmpl"
  local out
  out="$(iw feat/one -r backend 2>&1)"

  assert_grep "the template gained the markers" "<!-- iwork:repos -->" "$tmpl"
  assert_grep "and the closing one" "<!-- /iwork:repos -->" "$tmpl"
  assert_grep "the placeholder is still there" "{{REPOS}}" "$tmpl"
  assert_grep "and the owner's own line is untouched" "My own note, which must survive." "$tmpl"
  assert_contains "the repair is announced, not silent" "added <!-- iwork:repos --> markers" "$out"

  # The point of the repair: add-repo can now correct the list it writes.
  assert_grep "the task got a marked block" "<!-- iwork:repos -->" "$SB_TASKS/feat-one/CLAUDE.md"
  iw_in "$SB_TASKS/feat-one" add-repo -r frontend >/dev/null 2>&1
  assert_grep "and add-repo refreshed it" "frontend" "$SB_TASKS/feat-one/CLAUDE.md"
}

test_context_template_upgrade_runs_once() {
  mk_repo backend
  write_old_template
  local tmpl="$SB_HOME/.config/iwork/task-context.md.tmpl"

  iw feat/one -r backend >/dev/null 2>&1
  local first
  first="$(cat "$tmpl")"

  # A second task must not add a second pair, nor say anything.
  local out
  out="$(iw feat/two -r backend 2>&1)"
  assert_eq "the template is unchanged the second time" "$first" "$(cat "$tmpl")"
  assert_eq "markers appear exactly once" "1" "$(grep -c '^<!-- iwork:repos -->$' "$tmpl")"
  case "$out" in
    *"added <!-- iwork:repos --> markers"*) bad "announced the repair twice" ;;
    *) ok ;;
  esac
}

test_context_template_upgrade_leaves_odd_shapes_alone() {
  mk_repo backend
  mk_repo frontend
  # Inlined, so wrapping the line would make refresh_task_blocks overwrite the
  # prose around it. Left to its owner instead.
  cat > "$SB_HOME/.config/iwork/task-context.md.tmpl" <<'TMPL'
# Task: {{TASK}}

Repos: {{REPOS}}
TMPL
  local tmpl="$SB_HOME/.config/iwork/task-context.md.tmpl"
  local before
  before="$(cat "$tmpl")"

  local out
  out="$(iw feat/one -r backend 2>&1)"
  assert_eq "an inlined placeholder is not rewritten" "$before" "$(cat "$tmpl")"
  case "$out" in
    *"added <!-- iwork:repos --> markers"*) bad "claimed a repair it did not make" ;;
    *) ok ;;
  esac

  # And the existing warning still fires where it matters.
  out="$(iw_in "$SB_TASKS/feat-one" add-repo -r frontend 2>&1 || true)"
  assert_contains "add-repo still says the list is stale" "iwork:repos" "$out"
}

# --- master ------------------------------------------------------------------

test_master_hook_gives_the_project_role() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  local out
  out="$(hook_fire "$SB_PROJECTS/myproj" '{"hook_event_name":"SessionStart"}')"
  assert_contains "says which project it is master of" \
    "master session for project 'myproj'" "$out"
  assert_contains "carries the project brief" "Tasks (live)" "$out"
  assert_contains "names the verb that spawns a task" "iwork <branch> -r" "$out"
  assert_contains "keeps rm on the operator's side" "iwork rm" "$out"
  assert_contains "explains what the session is for" "stacks on" "$out"
  assert_contains "and how to reach a task's agent" "Reaching a task's agent" "$out"
  # The inbox cannot wake an agent that is already at its prompt; the brief has
  # to say so, or the master waits on a message that will never be read.
  # The queue cannot wake an idle agent, and most agents are idle most of the
  # time. A master that does not know to use its own session messaging waits
  # forever on a message nobody will read.
  assert_contains "names the live channel" "SendMessage" "$out"
  assert_contains "and how to find who to send to" "ListAgents" "$out"
  assert_contains "naming the key it pairs on" "on the pane" "$out"
  assert_contains "and says to verify it landed" "did not land" "$out"
  # A task with nothing running is started with its instruction, not messaged.
  assert_contains "and what to do when nothing is running there" "claude <task>" "$out"
  # -m after the subcommand is forwarded to claude, which rejects it; the brief
  # got this wrong once and the failure is silent.
  assert_contains "with the flag where it actually works" '-m "<what to do>" claude' "$out"
  assert_contains "with durable notes going to the log instead" "iwork decided" "$out"

  # The two roles are mutually exclusive: a master told to stay inside one task
  # is a master that will not spawn the next one.
  case "$out" in
    *"this task belongs to project"*) bad "gave the master the task brief" ;;
    *) ok ;;
  esac
}

test_task_session_still_gets_the_task_brief() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  local out
  out="$(hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionStart"}')"
  assert_contains "a task still gets the task brief" "this task belongs to project" "$out"
  case "$out" in
    *"master session for project"*) bad "gave a task the master brief" ;;
    *) ok ;;
  esac
}

test_master_registers_with_its_role() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  local WANT_SESSION_ID="sess-master" WANT_CLAUDE_PID="$$"
  hook_fire "$SB_PROJECTS/myproj" '{"hook_event_name":"SessionStart"}' >/dev/null

  local out
  out="$(iw project agents myproj 2>&1)"
  assert_contains "the master is listed" "sess-master" "$out"
  assert_contains "under its role rather than as an unknown task" "(master)" "$out"

  out="$(iw project show myproj 2>&1)"
  assert_contains "project show says the master is live" "Master: live" "$out"

  # It belongs to the project, not to any task in it.
  case "$out" in
    *"1 agent"*) bad "counted the master against a task" ;;
    *) ok ;;
  esac
}

test_master_deregisters_on_session_end() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  local WANT_SESSION_ID="sess-master" WANT_CLAUDE_PID="$$"
  hook_fire "$SB_PROJECTS/myproj" '{"hook_event_name":"SessionStart"}' >/dev/null
  hook_fire "$SB_PROJECTS/myproj" '{"hook_event_name":"SessionEnd"}' >/dev/null

  assert_contains "the master is gone from the listing" "(none)" \
    "$(iw project agents myproj 2>&1)"
  assert_contains "and project show says so" "Master: not running" \
    "$(iw project show myproj 2>&1)"
}

test_master_resolves_the_project_from_where_it_stands() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # --no-tmux is the default in the sandbox, so this cds and execs the claude
  # stub: what is under test is which project it resolved before doing so.
  assert_ok "from inside a task, through its .project link" \
    iw_in "$SB_TASKS/feat-one" master
  assert_ok "from the project directory itself" \
    iw_in "$SB_PROJECTS/myproj" master
  assert_ok "named explicitly from anywhere" iw master myproj
  assert_fails "an unknown project is refused" iw master nosuchproject
  assert_fails "and so is a second positional" iw master myproj otherproj
}

test_master_says_when_the_hooks_are_missing() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # The role is delivered by the SessionStart hook and by nothing else, so a
  # master started without it comes up as an ordinary agent in a markdown
  # directory. Coming up looking fine is the failure mode worth catching.
  assert_contains "warns that the session will have no role" "install-hooks" \
    "$(iw master myproj 2>&1)"
}

test_master_window_is_created_and_reused() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  WANT_TMUX=1 iw master myproj >/dev/null 2>&1

  local windows
  windows="$(tmux_t list-windows -t '=projects-myproj' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
  assert_contains "a master window was created in the project's own session" "myproj" "$windows"

  # Two masters would plan against the same PROJECT.md and spawn overlapping
  # tasks, with neither aware of the other.
  assert_contains "a second master is refused" "already open" \
    "$(WANT_TMUX=1 iw master myproj 2>&1)"

  local count
  count="$(tmux_t list-windows -t '=projects-myproj' -F '#{window_name}' 2>/dev/null | grep -c myproj)"
  assert_eq "and no second window was made" "1" "$(printf '%s' "$count" | tr -d ' ')"

  # The shared session is not where a master lives.
  local task_windows
  task_windows="$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
  case "$task_windows" in
    *myproj*) bad "the master landed in the shared tasks session" ;;
    *) ok ;;
  esac
}

test_master_takes_the_first_window_of_its_session() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend

  # The task exists before the master here, which is the case that needs the
  # insert: appending would leave the master last in its own session.
  WANT_TMUX=1 iw --detach feat/one -r backend -p myproj >/dev/null 2>&1
  WANT_TMUX=1 iw master myproj >/dev/null 2>&1

  local first
  first="$(tmux_t list-windows -t '=projects-myproj' -F '#{window_name}' 2>/dev/null | head -1)"
  assert_eq "the master is the first window" "myproj" "$first"
  assert_contains "with the task after it" "feat-one" \
    "$(tmux_t list-windows -t '=projects-myproj' -F '#{window_name}' 2>/dev/null | tail -n +2 | tr '\n' ' ')"
}

test_project_delete_takes_the_session_with_it() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  # delete refuses while a task is attached, so the project has to be emptied
  # first — leaving the master as the only thing in the session.
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw project rm myproj feat-one >/dev/null 2>&1
  WANT_TMUX=1 iw master myproj >/dev/null 2>&1
  tmux_t has-session -t '=projects-myproj' 2>/dev/null || {
    printf '    skip (master session not created in this environment)\n'
    return 0
  }

  # A session named after a project that no longer exists, with a master in it
  # reading memory that is gone, is worse than no session at all.
  local out
  out="$(WANT_TMUX=1 iw project delete -f myproj 2>&1)"
  assert_contains "the confirmation says the session goes too" "projects-myproj" "$out"
  if tmux_t has-session -t '=projects-myproj' 2>/dev/null; then
    bad "delete left the project's session behind"
  else
    ok
  fi
}

test_master_gathers_a_projects_stray_windows() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw feat/two -r backend -p myproj >/dev/null 2>&1
  iw feat/loose -r backend >/dev/null 2>&1

  # The state every project created before the layout change is in: its tasks
  # are windows in the shared session, and nothing moves a window by itself.
  tmux_t new-session -d -s tasks -n feat-one -c "$SB_TASKS/feat-one" 2>/dev/null
  tmux_t new-window -d -t '=tasks' -n feat-two -c "$SB_TASKS/feat-two" 2>/dev/null
  tmux_t new-window -d -t '=tasks' -n feat-loose -c "$SB_TASKS/feat-loose" 2>/dev/null
  tmux_t has-session -t '=tasks' 2>/dev/null || {
    printf '    skip (could not start isolated tmux server)\n'
    return 0
  }

  # Opening the master is the moment the project's session exists, so it is
  # where the strays are collected.
  local out
  out="$(WANT_TMUX=1 iw master myproj 2>&1)"
  assert_contains "says it moved the first one" "moved tmux window 'feat-one'" "$out"
  assert_contains "and the second" "moved tmux window 'feat-two'" "$out"

  local gathered
  gathered="$(tmux_t list-windows -t '=projects-myproj' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
  assert_contains "the project's tasks are in its session" "feat-one" "$gathered"
  assert_contains "both of them" "feat-two" "$gathered"

  # A task belonging to no project is none of the project's business.
  local shared
  shared="$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
  assert_contains "the loose task was left alone" "feat-loose" "$shared"
  case "$shared" in
    *feat-one*|*feat-two*) bad "a project task was left in the shared session" ;;
    *) ok ;;
  esac

  # Idempotent: nothing left to move, so nothing is said about moving.
  out="$(WANT_TMUX=1 iw master myproj 2>&1)"
  case "$out" in
    *"moved tmux window"*) bad "a second master start moved windows again" ;;
    *) ok ;;
  esac
}

test_master_left_in_the_old_shared_session_is_adopted() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw feat/two -r backend -p other >/dev/null 2>&1

  # The world as it was: every master a window in one shared 'projects' session.
  tmux_t new-session -d -s projects -n myproj -c "$SB_PROJECTS/myproj" 2>/dev/null
  tmux_t new-window -d -t '=projects' -n other -c "$SB_PROJECTS/other" 2>/dev/null
  tmux_t has-session -t '=projects' 2>/dev/null || {
    printf '    skip (could not start isolated tmux server)\n'
    return 0
  }

  local out
  out="$(WANT_TMUX=1 iw --detach master myproj 2>&1)"
  assert_contains "says where the master was" "old shared 'projects' session" "$out"
  assert_contains "and that it moved it" "moved tmux window 'myproj'" "$out"

  # Adopted, not duplicated: the running agent keeps its pane, and no second
  # master is started against the same PROJECT.md.
  assert_contains "the master is not started twice" "already open" "$out"
  assert_eq "it is the first window of the project's session" "myproj" \
    "$(tmux_t list-windows -t '=projects-myproj' -F '#{window_name}' 2>/dev/null | head -1)"

  # Another project's master is nobody else's business.
  assert_contains "the other master was left where it was" "other" \
    "$(tmux_t list-windows -t '=projects' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
}

test_attach_and_detach_move_the_tasks_window() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  WANT_TMUX=1 iw master myproj >/dev/null 2>&1
  WANT_TMUX=1 iw --detach feat/two -r backend >/dev/null 2>&1

  # feat-two starts loose, in the shared session.
  assert_contains "starts in the shared session" "feat-two" \
    "$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"

  local out
  out="$(WANT_TMUX=1 iw project add myproj feat-two 2>&1)"
  assert_contains "attaching says where the window went" "moved tmux window 'feat-two'" "$out"
  assert_contains "and it is in the project session" "feat-two" \
    "$(tmux_t list-windows -t '=projects-myproj' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"

  out="$(WANT_TMUX=1 iw project rm myproj feat-two 2>&1)"
  assert_contains "detaching moves it back" "moved tmux window 'feat-two'" "$out"
  assert_contains "to the shared session" "feat-two" \
    "$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
}

test_task_created_from_the_project_directory_joins_it() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  iw_in "$SB_PROJECTS/myproj" feat/two -r backend >/dev/null 2>&1
  assert_link "the new task was attached without -p" "$SB_TASKS/feat-two/.project"
  assert_eq "to the project it was created from" "myproj" \
    "$(basename "$(readlink "$SB_TASKS/feat-two/.project")")"
}

test_rm_refuses_from_the_project_directory() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # confirm() reads /dev/tty, which a pane running an agent has, so the prompt
  # that would normally catch this is answered by the agent itself.
  assert_fails "rm refuses from the project directory" \
    iw_in "$SB_PROJECTS/myproj" rm -f feat-one
  assert_dir "and the task is still there" "$SB_TASKS/feat-one"
  assert_contains "saying where it will run instead" "cd' out first" \
    "$(iw_in "$SB_PROJECTS/myproj" rm -f feat-one 2>&1)"

  # From outside the project it is the operator's again.
  assert_ok "but not from outside the project" iw rm -f feat-one
}

test_project_delete_refuses_from_the_project_directory() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  assert_fails "project delete refuses from the project directory" \
    iw_in "$SB_PROJECTS/myproj" project delete -f myproj
  assert_dir "and the memory is still there" "$SB_PROJECTS/myproj"
}

test_from_is_recorded_in_the_project_history() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  iw feat/two --from feat-one -r backend -p myproj >/dev/null 2>&1

  # Once the task folders are gone this is the only record that the stack
  # existed, which is the point at which the stack matters.
  assert_grep "the base a task was stacked on is recorded" "from=feat-one" \
    "$SB_PROJECTS/myproj/history.tsv"
  assert_eq "and only the stacked task records one" "1" \
    "$(grep -c 'from=' "$SB_PROJECTS/myproj/history.tsv" | tr -d ' ')"
}

test_agents_row_with_a_pane_but_no_pid_still_lists() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # Tab is IFS whitespace, so 'read' collapsed the empty pid into the pane and
  # this row was dropped by 'kill -0 %3'. A harness that exports a pane but no
  # pid was invisible in the listing that exists to find it.
  printf '2026-01-01T00:00:00+0000\tregistered\tfeat-one\tsess-pane\t\t%%3\t\ttask\n' \
    >> "$SB_PROJECTS/myproj/agents.tsv"

  local out
  out="$(iw project agents myproj 2>&1)"
  assert_contains "a row with a pane but no pid is still listed" "sess-pane" "$out"
  assert_contains "and its pane is the field that survives" "%3" "$out"
}

test_agents_json_is_parseable_and_joinable() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  local WANT_SESSION_ID="sess-task" WANT_CLAUDE_PID="$$" WANT_PANE="%7"
  hook_fire "$SB_TASKS/feat-one" '{"hook_event_name":"SessionStart"}' >/dev/null

  local out
  out="$(iw project agents --json myproj 2>&1)"
  assert_ok "the json parses" python3 -c 'import json,sys; json.load(sys.stdin)' <<<"$out"
  assert_contains "carries a version for consumers to check" '"api_version": 1' "$out"
  assert_contains "names the project" '"project": "myproj"' "$out"
  assert_contains "carries the session id to join on" '"session": "sess-task"' "$out"
  assert_contains "and the pane to fall back to" '"pane": "%7"' "$out"
  assert_contains "with the role" '"role": "task"' "$out"

  # An empty column is null rather than "", so a consumer testing for a pane
  # does not have to know that "" means there is none.
  printf '2026-01-01T00:00:00+0000\tregistered\t\tsess-bare\t\t\t\tmaster\n' \
    >> "$SB_PROJECTS/myproj/agents.tsv"
  out="$(iw project agents --json myproj 2>&1)"
  assert_ok "still parses with empty columns" python3 -c 'import json,sys; json.load(sys.stdin)' <<<"$out"
  assert_contains "a master has no task" '"task": null' "$out"
  assert_contains "and an absent pane is null" '"pane": null' "$out"
}

test_agents_json_is_empty_but_valid_with_no_agents() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  local out
  out="$(iw project agents --json myproj 2>&1)"
  assert_ok "an empty listing is still valid json" \
    python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["agents"]==[] else 1)' <<<"$out"
}

test_agents_tsv_keeps_empty_columns_as_columns() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  printf '2026-01-01T00:00:00+0000\tregistered\tfeat-one\tsess-pane\t\t%%3\t\ttask\n' \
    >> "$SB_PROJECTS/myproj/agents.tsv"

  local out
  out="$(iw project agents --tsv myproj 2>&1)"
  # Columns: task, role, session, pid, pane, transcript, last_active_seconds.
  assert_eq "the pane stays in column 5 despite the empty pid" "%3" \
    "$(printf '%s\n' "$out" | awk -F'\t' '$3 == "sess-pane" { print $5 }')"
  assert_eq "and the role in column 2" "task" \
    "$(printf '%s\n' "$out" | awk -F'\t' '$3 == "sess-pane" { print $2 }')"
}

test_agents_format_flags_are_exclusive() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  assert_fails "--json and --tsv together are refused" \
    iw project agents --json --tsv myproj
  assert_fails "an unknown format flag is still refused" \
    iw project agents --yaml myproj
}


test_message_flag_after_the_subcommand_is_refused() {
  mk_repo backend
  iw feat/one -r backend >/dev/null 2>&1

  # It used to be forwarded to claude, which errors in a pane nobody is
  # watching: the window is left at a shell and the listing says 'open', which
  # is what a task you opened by hand looks like.
  assert_fails "-m after the task name is refused" \
    iw claude feat-one -m "do the thing"
  assert_contains "and says where it goes instead" 'iwork -m "<message>" claude' \
    "$(iw claude feat-one -m "do the thing" 2>&1)"
  assert_fails "same for codex" iw codex feat-one --message "do the thing"
}

# --- resurrect ----------------------------------------------------------------

# The claude stub exits the moment it is sent into a pane, so a task created in
# the sandbox already looks exactly like one whose agent a dead tmux server took
# with it: the window is there, the pane is back at a shell.

test_resurrect_restarts_a_dead_agent_pane() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach feat/one -r backend >/dev/null 2>&1

  local out
  out="$(WANT_TMUX=1 iw resurrect 2>&1)"
  assert_contains "the dead pane is restarted" "feat-one: restarted" "$out"
  assert_contains "and resumes the conversation it was having" "claude --continue" "$out"

  # The window it already had is the one it keeps: a second one would be a
  # second agent for the same worktrees.
  local count
  count="$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | grep -c '^feat-one$')"
  assert_eq "no second window was made" "1" "$(printf '%s' "$count" | tr -d ' ')"
}

test_resurrect_opens_a_window_for_a_task_that_has_none() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  # Created with tmux off, so the task exists on disk with no window anywhere —
  # which is what every task looks like after a server is lost outright.
  iw feat/one -r backend >/dev/null 2>&1

  assert_contains "a window is opened for it" "feat-one: opened a window" \
    "$(WANT_TMUX=1 iw resurrect 2>&1)"
  assert_contains "in the session the task belongs to" "feat-one" \
    "$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
}

test_resurrect_closes_a_window_whose_task_is_gone() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach feat/one -r backend >/dev/null 2>&1

  # Deleted behind iwork's back, which is how a restorer ends up replaying a
  # window for a task that no longer exists.
  rm -rf "$SB_TASKS/feat-one"

  assert_contains "the leftover window is closed" "closed window 'feat-one'" \
    "$(WANT_TMUX=1 iw resurrect 2>&1)"
  case "$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')" in
    *feat-one*) bad "resurrect left the leftover window behind" ;;
    *) ok ;;
  esac
}

test_resurrect_never_closes_a_window_with_something_running() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach feat/one -r backend >/dev/null 2>&1

  local pane
  pane="$(tmux_t list-panes -t '=tasks:feat-one' -F '#{pane_id}' 2>/dev/null | head -1)"
  # 'cat' with no argument blocks on stdin forever, so the pane reports a live
  # foreground job without the suite having to sleep for one.
  tmux_t send-keys -t "$pane" 'cat' Enter 2>/dev/null
  wait_for_pane_command "$pane" cat || { printf '    skip (pane never ran cat)\n'; return 0; }
  rm -rf "$SB_TASKS/feat-one"

  local out
  out="$(WANT_TMUX=1 iw resurrect 2>&1)"
  assert_contains "it says why the window was spared" "running 'cat'" "$out"
  assert_contains "the window is still there" "feat-one" \
    "$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
}

test_resurrect_never_types_into_a_pane_that_is_busy() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach feat/one -r backend >/dev/null 2>&1

  local pane
  pane="$(tmux_t list-panes -t '=tasks:feat-one' -F '#{pane_id}' 2>/dev/null | head -1)"
  tmux_t send-keys -t "$pane" 'cat' Enter 2>/dev/null
  wait_for_pane_command "$pane" cat || { printf '    skip (pane never ran cat)\n'; return 0; }

  # Typing 'claude --continue' at an editor puts it in a buffer, so a pane that
  # is not an idle shell is reported and left alone.
  local out
  out="$(WANT_TMUX=1 iw resurrect 2>&1)"
  assert_contains "the busy pane is left alone" "left alone" "$out"
  case "$out" in
    *"feat-one: restarted"*) bad "resurrect typed into a busy pane" ;;
    *) ok ;;
  esac
}

test_resurrect_dry_run_changes_nothing() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach feat/one -r backend >/dev/null 2>&1
  iw feat/two -r backend >/dev/null 2>&1
  rm -rf "$SB_TASKS/feat-one"

  local out
  out="$(WANT_TMUX=1 iw resurrect -n 2>&1)"
  assert_contains "it says it is a dry run" "Dry run" "$out"
  assert_contains "and what it would close" "would close window 'feat-one'" "$out"
  assert_contains "and what it would open" "feat-two: would open" "$out"

  local windows
  windows="$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
  assert_contains "the leftover window is untouched" "feat-one" "$windows"
  case "$windows" in
    *feat-two*) bad "a dry run opened a window" ;;
    *) ok ;;
  esac
}

test_resurrect_leaves_a_big_tasks_own_session_alone() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  mk_repo frontend
  WANT_TMUX=1 iw --detach --big feat/one -r backend frontend >/dev/null 2>&1
  tmux_t has-session -t '=tasks-feat-one' 2>/dev/null || {
    printf '    skip (--big session not created in this environment)\n'; return 0; }

  WANT_TMUX=1 iw resurrect >/dev/null 2>&1

  # The repo windows in a --big session are named after repos, not tasks. A
  # sweep that read them as task windows would close every one of them.
  local windows
  windows="$(tmux_t list-windows -t '=tasks-feat-one' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
  assert_contains "the agent window survives" "feat-one" "$windows"
  assert_contains "and so does the backend repo window" "backend" "$windows"
  assert_contains "and the frontend one" "frontend" "$windows"
}

test_resurrect_big_restores_a_task_to_its_own_session() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  # Bigness is recorded in the session layout and nowhere on disk, so a task
  # whose session died can only come back big by being named.
  iw feat/one -r backend >/dev/null 2>&1

  WANT_TMUX=1 iw resurrect --big feat-one >/dev/null 2>&1
  if ! tmux_t has-session -t '=tasks-feat-one' 2>/dev/null; then
    printf '    skip (--big session not created in this environment)\n'
    return 0
  fi
  ok

  case "$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')" in
    *feat-one*) bad "the big task also got a window in the shared session" ;;
    *) ok ;;
  esac

  assert_contains "and list says it owns a session" "(session)" \
    "$(WANT_TMUX=1 iw --big list 2>&1 | grep feat-one)"
}

test_resurrect_big_refuses_a_task_that_is_not_there() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 assert_fails "--big on a task that does not exist is refused" \
    iw resurrect --big feat-nope
  assert_contains "and says so" "no such task" \
    "$(WANT_TMUX=1 iw resurrect --big feat-nope 2>&1)"
}

test_resurrect_keeps_a_master_window() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  WANT_TMUX=1 iw master myproj >/dev/null 2>&1

  # A master window is named after its project, and no task of that name exists.
  # A sweep that did not know the difference would close it.
  WANT_TMUX=1 iw resurrect >/dev/null 2>&1
  assert_contains "the master window survives the sweep" "myproj" \
    "$(tmux_t list-windows -t '=projects-myproj' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
}

test_resurrect_gathers_a_projects_task_back_into_its_session() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach feat/one -r backend -p myproj >/dev/null 2>&1
  tmux_t has-session -t '=projects-myproj' 2>/dev/null || {
    printf '    skip (project session not created in this environment)\n'; return 0; }

  # A restorer rebuilds windows from a snapshot with no idea which session each
  # one belongs in, so drift like this is exactly what it leaves behind.
  tmux_t new-session -d -s tasks 2>/dev/null
  tmux_t move-window -s '=projects-myproj:feat-one' -t '=tasks:' 2>/dev/null

  WANT_TMUX=1 iw resurrect >/dev/null 2>&1

  assert_contains "the task is back in its project's session" "feat-one" \
    "$(tmux_t list-windows -t '=projects-myproj' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
  case "$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')" in
    *feat-one*) bad "resurrect left the task in the shared session" ;;
    *) ok ;;
  esac
}

test_resurrect_is_refused_without_tmux() {
  mk_repo backend
  # Its whole job is repairing tmux state, so silently doing nothing would be
  # the wrong answer.
  assert_fails "resurrect refuses with --no-tmux" iw resurrect
  assert_contains "and says why" "repairs tmux" "$(iw resurrect 2>&1)"
}

test_resurrect_rejects_an_unknown_argument() {
  assert_fails "a stray argument is refused" iw resurrect feat-one
  assert_contains "with the usage line" "iwork resurrect" "$(iw resurrect feat-one 2>&1)"
}

# --- rm from inside the thing being killed ------------------------------------

# iw() runs iwork outside tmux, which can never reach the case these cover: the
# window or session being destroyed is the one the caller is standing in. That
# only happens when iwork runs *in* the pane, so it gets a runner of its own,
# carrying the same sandbox environment iw() does.
make_pane_runner() {
  cat > "$SB/bin/iwp" <<RUNNER
#!/bin/bash
export PATH="$SB/bin:\$PATH"
export HOME="$SB_HOME"
export GIT_CONFIG_GLOBAL="$SB_HOME/.gitconfig"
export TMUX_TMPDIR="$SB/tmux"
export IWORK_CONFIG_FILE="$SB/config"
export IWORK_REPO_DIR="$SB_REPOS"
export IWORK_TASKS_DIR="$SB_TASKS"
export IWORK_PROJECTS_DIR="$SB_PROJECTS"
export IWORK_EDITOR="nvim"
export IWORK_ASSUME_YES=1
export CLAUDE_CODE_SESSION_ID=""
export CLAUDE_PID=""
exec "$IWORK_SRC" "\$@"
RUNNER
  chmod +x "$SB/bin/iwp"
}

wait_until_gone() {
  local path="$1" waited=0

  while (( waited < 100 )); do
    [[ -e "$path" ]] || return 0
    command sleep 0.1
    waited=$((waited + 1))
  done

  return 1
}

test_rm_kills_the_window_you_are_standing_in() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach feat/one -r backend >/dev/null 2>&1
  # A second task, so there is somewhere for the client to be moved to.
  WANT_TMUX=1 iw --detach feat/two -r backend >/dev/null 2>&1
  make_pane_runner

  local pane
  pane="$(tmux_t list-panes -t '=tasks:feat-one' -F '#{pane_id}' 2>/dev/null | head -1)"
  [[ -n "$pane" ]] || { printf '    skip (no pane for the task)\n'; return 0; }

  # This used to warn "close it yourself" and leave both the window and the
  # folder in place.
  tmux_t send-keys -t "$pane" 'iwp rm -f feat-one' Enter 2>/dev/null

  if ! wait_until_gone "$SB_TASKS/feat-one"; then
    bad "rm never removed the task folder from inside its own window"
    return 0
  fi
  ok

  # The deferred kill lands just after the folder goes, so give it a moment.
  local waited=0
  while (( waited < 50 )); do
    case "$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')" in
      *feat-one*) command sleep 0.1; waited=$((waited + 1)) ;;
      *) break ;;
    esac
  done

  local windows
  windows="$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')"
  case "$windows" in
    *feat-one*) bad "rm left the window it was standing in behind" ;;
    *) ok ;;
  esac
  assert_contains "and the other task is untouched" "feat-two" "$windows"
}

test_rm_kills_the_big_session_you_are_standing_in() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  mk_repo frontend
  WANT_TMUX=1 iw --detach --big feat/one -r backend frontend >/dev/null 2>&1
  tmux_t has-session -t '=tasks-feat-one' 2>/dev/null || {
    printf '    skip (--big session not created in this environment)\n'; return 0; }
  # Somewhere to land: without this the client would simply detach.
  WANT_TMUX=1 iw --detach feat/two -r backend >/dev/null 2>&1
  make_pane_runner

  local pane
  pane="$(tmux_t list-panes -t '=tasks-feat-one:feat-one' -F '#{pane_id}' 2>/dev/null | head -1)"
  [[ -n "$pane" ]] || { printf '    skip (no pane for the task)\n'; return 0; }

  tmux_t send-keys -t "$pane" 'iwp rm -f feat-one' Enter 2>/dev/null

  if ! wait_until_gone "$SB_TASKS/feat-one"; then
    bad "rm never removed the task folder from inside its own session"
    return 0
  fi
  ok

  local waited=0
  while (( waited < 50 )); do
    tmux_t has-session -t '=tasks-feat-one' 2>/dev/null || break
    command sleep 0.1
    waited=$((waited + 1))
  done

  if tmux_t has-session -t '=tasks-feat-one' 2>/dev/null; then
    bad "rm left the session it was standing in behind"
  else
    ok
  fi
  assert_dir "and the other task survived" "$SB_TASKS/feat-two"
}

test_rm_from_another_window_still_kills_immediately() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach feat/one -r backend >/dev/null 2>&1

  # Nothing is deferred when the caller is not standing in the target, so the
  # window is gone by the time rm returns.
  WANT_TMUX=1 iw rm -f feat-one >/dev/null 2>&1

  case "$(tmux_t list-windows -t '=tasks' -F '#{window_name}' 2>/dev/null | tr '\n' ' ')" in
    *feat-one*) bad "rm left the task window behind" ;;
    *) ok ;;
  esac
  assert_no_file "and the task folder is gone" "$SB_TASKS/feat-one"
}

# --- files nobody claimed ----------------------------------------------------

# An agent that writes a note at the task root rather than inside a repo used to
# make the task un-removable: rm took the worktrees, rmdir found the folder
# non-empty, and the run reported success while leaving the folder behind for
# you to finish by hand.

test_rm_lists_and_removes_files_it_did_not_create() {
  mk_repo backend
  iw feat/one -r backend >/dev/null 2>&1
  printf 'notes\n' > "$SB_TASKS/feat-one/HANDOFF.md"
  printf 'x\n' > "$SB_TASKS/feat-one/report.html"

  local out
  out="$(iw rm -f feat-one 2>&1)"

  # Listed before they go, which is the whole safety story now that they do go.
  assert_contains "the stray note is named in the plan" "HANDOFF.md" "$out"
  assert_contains "and so is the other file" "report.html" "$out"
  assert_contains "and said not to be iwork's" "iwork did not put it here" "$out"
  assert_no_file "the task folder is actually gone" "$SB_TASKS/feat-one"
}

test_rm_takes_stray_dotfiles_too() {
  mk_repo backend
  iw feat/one -r backend >/dev/null 2>&1
  # A stray dotfile is exactly the kind of thing that kept a folder alive while
  # being invisible in the listing that explained why.
  printf 'SECRET=1\n' > "$SB_TASKS/feat-one/.env"

  local out
  out="$(iw rm -f feat-one 2>&1)"
  assert_contains "the dotfile is named" ".env" "$out"
  assert_no_file "and the folder is gone" "$SB_TASKS/feat-one"
}

test_rm_does_not_list_its_own_files_as_strays() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # CLAUDE.md, AGENTS.md, .claude and .project are removed by name further
  # down; listing them here as well would be noise.
  local out
  out="$(iw rm -f feat-one 2>&1)"
  assert_no_grep_str "CLAUDE.md is not called a stray" "CLAUDE.md  (not a worktree" "$out"
  assert_no_grep_str "nor is the project link" ".project  (not a worktree" "$out"
  assert_no_file "and the folder still goes" "$SB_TASKS/feat-one"
}

test_rm_of_one_repo_leaves_stray_files_alone() {
  mk_repo backend
  mk_repo frontend
  iw feat/one -r backend frontend >/dev/null 2>&1
  printf 'notes\n' > "$SB_TASKS/feat-one/HANDOFF.md"

  # The task survives a partial removal, so nothing at its root is in scope.
  local out
  out="$(iw rm -f feat-one -r frontend 2>&1)"
  assert_no_file "the named worktree is gone" "$SB_TASKS/feat-one/frontend"
  assert_file "the stray file is untouched" "$SB_TASKS/feat-one/HANDOFF.md"
  case "$out" in
    *"iwork did not put it here"*) bad "a partial removal listed stray files" ;;
    *) ok ;;
  esac
}

test_rm_does_not_mistake_a_worktree_for_a_stray() {
  mk_repo backend
  iw feat/one -r backend >/dev/null 2>&1

  local out
  out="$(iw rm -f feat-one 2>&1)"
  case "$out" in
    *"backend  (not a worktree"*) bad "a worktree was listed as a stray file" ;;
    *) ok ;;
  esac
  assert_contains "it is listed as the worktree it is" "- backend" "$out"
}

# --- duplicate sessions -------------------------------------------------------

# A marked session does not reserve its plain name, so tmux will happily hold
# '!tasks' and 'tasks' at the same time -- which is how one logical session ends
# up split in two, with every lookup answering from whichever it sees first.
# Building that state by hand is exactly what the race produces.

test_a_marked_session_does_not_reserve_its_plain_name() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach feat/one -r backend >/dev/null 2>&1
  tmux_t rename-session -t '=tasks' '!tasks' 2>/dev/null

  # The premise of the whole bug: if tmux refused this, no duplicate could ever
  # exist and none of the folding below would be needed.
  assert_ok "tmux allows a second session under the unmarked name" \
    tmux_t new-session -d -s tasks -n stray
  assert_eq "so two sessions now share one base" "2" \
    "$(tmux_t list-sessions -F '#{session_name}' 2>/dev/null | sed 's/^[*!]//' | grep -c '^tasks$' | tr -d ' ')"
}

test_resurrect_folds_a_split_session_back_together() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach feat/one -r backend >/dev/null 2>&1
  WANT_TMUX=1 iw --detach feat/two -r backend >/dev/null 2>&1
  tmux_t rename-session -t '=tasks' '!tasks' 2>/dev/null

  # feat/three lands in a second, unmarked 'tasks' -- the split the race makes.
  iw feat/three -r backend >/dev/null 2>&1
  tmux_t new-session -d -s tasks -n feat-three 2>/dev/null

  assert_contains "resurrect reports the fold" "folded the duplicate tmux sessions" \
    "$(WANT_TMUX=1 iw resurrect 2>&1)"

  assert_eq "one session is left under that name" "1" \
    "$(tmux_t list-sessions -F '#{session_name}' 2>/dev/null | sed 's/^[*!]//' | grep -c '^tasks$' | tr -d ' ')"

  # The point of folding rather than killing: nothing that was open is lost.
  local windows
  windows="$(windows_of_session tasks)"
  assert_contains "the first task survived" "feat-one" "$windows"
  assert_contains "the second too" "feat-two" "$windows"
  assert_contains "and the one from the duplicate came across" "feat-three" "$windows"
}

test_resurrect_dry_run_reports_duplicates_without_folding() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach feat/one -r backend >/dev/null 2>&1
  tmux_t rename-session -t '=tasks' '!tasks' 2>/dev/null
  tmux_t new-session -d -s tasks -n stray 2>/dev/null

  assert_contains "the dry run names the split" "would fold the duplicate tmux sessions" \
    "$(WANT_TMUX=1 iw resurrect -n 2>&1)"
  assert_eq "and both sessions are still there" "2" \
    "$(tmux_t list-sessions -F '#{session_name}' 2>/dev/null | sed 's/^[*!]//' | grep -c '^tasks$' | tr -d ' ')"
}

test_creating_a_task_folds_a_twin_it_finds() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach feat/one -r backend >/dev/null 2>&1
  tmux_t rename-session -t '=tasks' '!tasks' 2>/dev/null
  # The twin, as a losing invocation would have left it.
  tmux_t new-session -d -s tasks -n stray 2>/dev/null

  # Any later task creation resolves the marked one and folds the stray in
  # rather than adding to the split.
  WANT_TMUX=1 iw --detach feat/two -r backend >/dev/null 2>&1

  assert_eq "one session under that name" "1" \
    "$(tmux_t list-sessions -F '#{session_name}' 2>/dev/null | sed 's/^[*!]//' | grep -c '^tasks$' | tr -d ' ')"
  assert_contains "with the stray window folded in" "stray" \
    "$(windows_of_session tasks)"
}

# --- session markers are opt-in ----------------------------------------------

# Renaming a session to carry its agent state is the one thing iwork does that
# makes a session's *name* move under other tools. Every session switcher looks
# a session up by the name it last saw, and the ones that create what they
# cannot find build a second session under the stale name. So the rename is off
# by default and the state is published as a tmux option instead.

marker_hook() {
  local event="$1" pane="$2" socket="$3" markers="${4:-}"

  printf '{"hook_event_name":"%s"}' "$event" | env \
    TMUX="$socket,1,0" TMUX_PANE="$pane" TMUX_TMPDIR="$SB/tmux" \
    HOME="$SB_HOME" IWORK_CONFIG_FILE="$SB/config" \
    IWORK_REPO_DIR="$SB_REPOS" IWORK_TASKS_DIR="$SB_TASKS" \
    IWORK_PROJECTS_DIR="$SB_PROJECTS" \
    IWORK_SESSION_MARKERS="$markers" \
    "$IWORK_SRC" --hook >/dev/null 2>&1
}

marker_fixture() {
  mk_repo backend
  iw feat/one -r backend >/dev/null 2>&1
  tmux_t new-session -d -s tasks -n feat-one -c "$SB_TASKS/feat-one" 2>/dev/null
  MARKER_PANE="$(tmux_t list-panes -t '=tasks:feat-one' -F '#{pane_id}' 2>/dev/null | head -1)"
  MARKER_SOCKET="$(tmux_t display-message -p '#{socket_path}' 2>/dev/null)"
  [[ -n "$MARKER_PANE" && -n "$MARKER_SOCKET" ]]
}

test_session_name_is_left_alone_by_default() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  marker_fixture || { printf '    skip (could not start isolated tmux server)\n'; return 0; }

  marker_hook Stop "$MARKER_PANE" "$MARKER_SOCKET"

  assert_eq "the session keeps its plain name" "tasks" \
    "$(tmux_t display-message -p -t "$MARKER_PANE" '#{session_name}')"
  # The window still carries it: window names are iwork's own, and no switcher
  # keys on them.
  assert_eq "while the window still shows the state" "!feat-one" \
    "$(tmux_t display-message -p -t "$MARKER_PANE" '#{window_name}')"
}

test_session_state_is_published_as_a_tmux_option() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  marker_fixture || { printf '    skip (could not start isolated tmux server)\n'; return 0; }

  # Reading it back through a format is the point -- that is how a status line
  # or a picker gets at it. Writing it with a '=' session target silently did
  # nothing, which only a read-back catches.
  marker_hook Stop "$MARKER_PANE" "$MARKER_SOCKET"
  assert_eq "waiting is published" "!" \
    "$(tmux_t display-message -p -t "$MARKER_PANE" '#{@iwork_state}')"

  marker_hook UserPromptSubmit "$MARKER_PANE" "$MARKER_SOCKET"
  assert_eq "and so is working" "*" \
    "$(tmux_t display-message -p -t "$MARKER_PANE" '#{@iwork_state}')"
}

test_session_markers_can_be_turned_on() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  marker_fixture || { printf '    skip (could not start isolated tmux server)\n'; return 0; }

  marker_hook Stop "$MARKER_PANE" "$MARKER_SOCKET" on
  assert_eq "the name carries the marker when asked for" "!tasks" \
    "$(tmux_t display-message -p -t "$MARKER_PANE" '#{session_name}')"
  assert_eq "and the option is still published" "!" \
    "$(tmux_t display-message -p -t "$MARKER_PANE" '#{@iwork_state}')"
}

test_turning_markers_off_converges_a_marked_session_back() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  marker_fixture || { printf '    skip (could not start isolated tmux server)\n'; return 0; }

  marker_hook Stop "$MARKER_PANE" "$MARKER_SOCKET" on
  assert_eq "marked while the feature was on" "!tasks" \
    "$(tmux_t display-message -p -t "$MARKER_PANE" '#{session_name}')"

  # Otherwise a tree marked before the setting changed would stay marked for as
  # long as those sessions live.
  marker_hook Stop "$MARKER_PANE" "$MARKER_SOCKET"
  assert_eq "and back to the plain name once it is off" "tasks" \
    "$(tmux_t display-message -p -t "$MARKER_PANE" '#{session_name}')"
}

test_fold_sessions_repairs_a_switcher_duplicate() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach feat/one -r backend >/dev/null 2>&1
  tmux_t rename-session -t '=tasks' '!tasks' 2>/dev/null

  # What a switcher does when it looks up the name it last saw, misses, and
  # creates one: an empty session under the stale name.
  tmux_t new-session -d -s tasks -n '' 2>/dev/null

  WANT_TMUX=1 iw --fold-sessions >/dev/null 2>&1

  assert_eq "one session is left under that name" "1" \
    "$(tmux_t list-sessions -F '#{session_name}' 2>/dev/null | sed 's/^[*!]//' | grep -c '^tasks$' | tr -d ' ')"
  assert_contains "with the real task still in it" "feat-one" "$(windows_of_session tasks)"
}

test_fold_sessions_refreshes_published_state() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach feat/one -r backend >/dev/null 2>&1

  # A window marked without a hook behind it -- folded in, moved, restored --
  # leaves the session advertising what was true before. That option is the only
  # place the state is published now, so a stale value is the status line lying.
  tmux_t rename-window -t '=tasks:feat-one' '!feat-one' 2>/dev/null

  WANT_TMUX=1 iw --fold-sessions >/dev/null 2>&1

  local pane
  pane="$(tmux_t list-panes -t '=tasks' -F '#{pane_id}' 2>/dev/null | head -1)"
  assert_eq "the session advertises what its windows say" "!" \
    "$(tmux_t display-message -p -t "$pane" '#{@iwork_state}')"

  # Sessions iwork does not own are none of its business.
  tmux_t new-session -d -s mine -n w 2>/dev/null
  WANT_TMUX=1 iw --fold-sessions >/dev/null 2>&1
  assert_eq "and a session iwork does not own is left alone" "mine" \
    "$(tmux_t list-sessions -F '#{session_name}' 2>/dev/null | grep '^mine$')"
}

test_tmux_config_is_printable_and_points_at_this_iwork() {
  local out
  out="$(iw --tmux-config 2>&1)"
  assert_contains "it sets the session-created guard" "set-hook -g session-created" "$out"
  assert_contains "calling this iwork" "--fold-sessions" "$out"
  assert_contains "and shows how to read the state" "@iwork_state" "$out"
}

# --- add-repo on a task whose repos drifted apart -----------------------------

# iwork's model is one branch across a task, but nothing enforces it: an agent
# can commit a worktree onto its own branch, and then there is no single branch
# for add-repo to follow.
drift_a_worktree() {
  local task="$1" repo="$2" branch="$3"
  git -C "$SB_TASKS/$task/$repo" checkout -q -b "$branch"
}

test_add_repo_lists_every_branch_when_they_disagree() {
  mk_repo backend
  mk_repo frontend
  mk_repo shared
  iw feat/one -r backend frontend >/dev/null 2>&1
  drift_a_worktree feat-one frontend feat/went-its-own-way

  local out
  out="$(iw add-repo feat-one -r shared 2>&1)"

  # Naming just the first disagreement left you without the list to choose from.
  assert_contains "the first branch is named" "feat/one" "$out"
  assert_contains "and so is the one that drifted" "feat/went-its-own-way" "$out"
  assert_contains "with the repo each is on" "frontend" "$out"
  assert_contains "and a way out" "-b <branch>" "$out"
  assert_no_file "nothing was added" "$SB_TASKS/feat-one/shared/.git"
}

test_add_repo_takes_the_branch_when_told() {
  mk_repo backend
  mk_repo frontend
  mk_repo shared
  iw feat/one -r backend frontend >/dev/null 2>&1
  drift_a_worktree feat-one frontend feat/went-its-own-way

  assert_ok "-b gets past the ambiguity" \
    iw add-repo feat-one -b feat/one -r shared
  assert_dir "and the worktree is there" "$SB_TASKS/feat-one/shared"
  assert_eq "on the branch that was named" "feat/one" \
    "$(git -C "$SB_TASKS/feat-one/shared" branch --show-current)"
}

test_add_repo_b_can_name_a_new_branch() {
  mk_repo backend
  mk_repo shared
  iw feat/one -r backend >/dev/null 2>&1

  # Not only for disambiguating: -b is also how a new repo joins on a branch of
  # its own, which is the state that made the task mixed in the first place.
  assert_ok "-b accepts a branch nothing is on yet" \
    iw add-repo feat-one -b feat/brand-new -r shared
  assert_eq "and the worktree is on it" "feat/brand-new" \
    "$(git -C "$SB_TASKS/feat-one/shared" branch --show-current)"
}

test_branch_flag_is_refused_when_creating_a_task() {
  mk_repo backend

  # The branch is the first argument there, so -b would be a second answer to
  # the same question.
  assert_fails "-b is refused on task creation" \
    iw feat/one -b feat/other -r backend
  assert_contains "and says where it belongs" "applies only to add-repo" \
    "$(iw feat/one -b feat/other -r backend 2>&1)"
}

test_project_add_lists_the_branches_too() {
  mk_repo backend
  mk_repo frontend
  iw feat/one -r backend frontend >/dev/null 2>&1
  drift_a_worktree feat-one frontend feat/went-its-own-way

  # A project records one branch per task, so this hits the same wall and used
  # to give the same dead-end message.
  local out
  out="$(iw project add myproj feat-one 2>&1)"
  assert_contains "the branches are listed" "feat/went-its-own-way" "$out"
  assert_contains "with its own way out" "records one branch per task" "$out"
}

# --- skills from the worktrees -----------------------------------------------

# Claude Code loads project skills from the directory the session is rooted in,
# and an iwork task is rooted above its worktrees -- so a skill defined in one
# of them was out of scope for the agent iwork starts, and every "invoke the
# <x>-skill" line in that repo's AGENTS.md silently could not be followed.

add_skill() {
  local repo="$1" name="$2"
  mkdir -p "$SB_REPOS/$repo/.claude/skills/$name"
  cat > "$SB_REPOS/$repo/.claude/skills/$name/SKILL.md" <<SKILL
---
name: $name
description: Test skill $name from $repo.
---
Body.
SKILL
  git -C "$SB_REPOS/$repo" add -A >/dev/null 2>&1
  git -C "$SB_REPOS/$repo" commit -qm "add $name" >/dev/null 2>&1
  # Worktrees branch from origin/main, so a commit that stays local is a commit
  # the task never sees.
  git -C "$SB_REPOS/$repo" push -q origin main >/dev/null 2>&1
}

test_skills_from_every_worktree_reach_the_task_root() {
  mk_repo backend
  mk_repo frontend
  add_skill backend db-migrations
  add_skill frontend translator-skill

  iw feat/one -r backend frontend >/dev/null 2>&1

  local skills="$SB_TASKS/feat-one/.claude/skills"
  assert_link "the backend skill is reachable" "$skills/db-migrations"
  assert_link "and so is the frontend one" "$skills/translator-skill"
  # Following the link has to land on a real skill, not just exist.
  assert_file "the link resolves to the skill itself" "$skills/translator-skill/SKILL.md"
}

test_a_skill_two_repos_both_define_is_qualified() {
  mk_repo backend
  mk_repo frontend
  add_skill backend code-review-skill
  add_skill frontend code-review-skill
  add_skill frontend only-frontend-skill

  iw feat/one -r backend frontend >/dev/null 2>&1

  local skills="$SB_TASKS/feat-one/.claude/skills"
  # Linking one of them under the bare name would hand the agent the other
  # repo's review rules without saying so — worse than the unknown-skill error
  # it replaces, because it looks like it worked.
  assert_no_file "no bare name is invented for an ambiguous skill" "$skills/code-review-skill"
  assert_link "the backend one is named for its repo" "$skills/backend-code-review-skill"
  assert_link "and so is the frontend one" "$skills/frontend-code-review-skill"
  assert_link "while an unambiguous skill keeps its plain name" "$skills/only-frontend-skill"

  assert_contains "and the clash is reported" "defined by more than one repo" \
    "$(iw --no-tmux claude feat-one 2>&1)"
}

test_skill_links_follow_the_repos_as_they_change() {
  mk_repo backend
  add_skill backend db-migrations
  iw feat/one -r backend >/dev/null 2>&1

  local skills="$SB_TASKS/feat-one/.claude/skills"
  assert_link "linked at creation" "$skills/db-migrations"

  # A repo gains and loses skills after the task was made; the task should not
  # keep advertising what is no longer there.
  rm -rf "$SB_TASKS/feat-one/backend/.claude/skills/db-migrations"
  mkdir -p "$SB_TASKS/feat-one/backend/.claude/skills/brand-new"
  printf -- '---\nname: brand-new\ndescription: New.\n---\nBody.\n' \
    > "$SB_TASKS/feat-one/backend/.claude/skills/brand-new/SKILL.md"

  iw --no-tmux claude feat-one >/dev/null 2>&1

  assert_no_file "the dropped skill's link is gone" "$skills/db-migrations"
  assert_link "and the new one is linked" "$skills/brand-new"
}

test_skill_linking_leaves_hand_made_entries_alone() {
  mk_repo backend
  add_skill backend db-migrations
  iw feat/one -r backend >/dev/null 2>&1

  # A real directory in there is somebody's own work, not ours to clear out.
  local skills="$SB_TASKS/feat-one/.claude/skills"
  mkdir -p "$skills/mine"
  printf -- '---\nname: mine\ndescription: Mine.\n---\nBody.\n' > "$skills/mine/SKILL.md"

  iw --no-tmux claude feat-one >/dev/null 2>&1

  assert_file "a hand-made skill survives a refresh" "$skills/mine/SKILL.md"
  assert_link "and the linked ones are still there" "$skills/db-migrations"
}

test_a_task_with_no_skills_gets_no_empty_claude_dir() {
  mk_repo backend
  iw feat/one -r backend >/dev/null 2>&1

  # An empty .claude/ in every task would be noise, and 'rm' would have to
  # explain it.
  assert_no_file "no skills, no directory" "$SB_TASKS/feat-one/.claude"
}

test_skills_command_heals_every_task_at_once() {
  mk_repo backend
  mk_repo frontend
  add_skill backend db-migrations
  add_skill frontend translator-skill

  iw feat/one -r backend >/dev/null 2>&1
  iw feat/two -r backend frontend >/dev/null 2>&1

  # The state a tree made before any of this existed is in: worktrees with
  # skills, and no links anywhere.
  rm -rf "$SB_TASKS/feat-one/.claude" "$SB_TASKS/feat-two/.claude"

  local out
  out="$(iw skills 2>&1)"
  assert_contains "it reports the first task" "feat-one" "$out"
  assert_contains "and the second" "feat-two" "$out"
  assert_link "the first is relinked" "$SB_TASKS/feat-one/.claude/skills/db-migrations"
  assert_link "and so is the second" "$SB_TASKS/feat-two/.claude/skills/translator-skill"
}

test_skills_command_takes_one_task() {
  mk_repo backend
  add_skill backend db-migrations
  iw feat/one -r backend >/dev/null 2>&1
  iw feat/two -r backend >/dev/null 2>&1
  rm -rf "$SB_TASKS/feat-one/.claude" "$SB_TASKS/feat-two/.claude"

  iw skills feat-one >/dev/null 2>&1

  assert_link "the named task is relinked" "$SB_TASKS/feat-one/.claude/skills/db-migrations"
  assert_no_file "and the other is left alone" "$SB_TASKS/feat-two/.claude"
}

test_skills_dry_run_changes_nothing() {
  mk_repo backend
  add_skill backend db-migrations
  iw feat/one -r backend >/dev/null 2>&1
  rm -rf "$SB_TASKS/feat-one/.claude"

  local out
  out="$(iw skills -n 2>&1)"
  assert_contains "it says it is a dry run" "Dry run" "$out"
  assert_contains "and what it would link" "1 skill(s)" "$out"
  assert_no_file "while nothing is written" "$SB_TASKS/feat-one/.claude"
}

test_skills_command_names_the_ambiguous_ones() {
  mk_repo backend
  mk_repo frontend
  add_skill backend code-review-skill
  add_skill frontend code-review-skill
  iw feat/one -r backend frontend >/dev/null 2>&1

  # Which name is ambiguous is the part the operator has to act on.
  assert_contains "the clash is named, not just counted" "'code-review-skill' comes from more than one repo" \
    "$(iw skills 2>&1)"
}

test_skills_command_refuses_an_unknown_task() {
  mk_repo backend
  iw feat/one -r backend >/dev/null 2>&1

  assert_fails "an unknown task is refused" iw skills feat-nope
  assert_contains "and says so" "no such task" "$(iw skills feat-nope 2>&1)"
  assert_fails "as is a second task name" iw skills feat-one feat-two
}

# --- cull --------------------------------------------------------------------

# A master cannot be protected by a prompt it answers itself, so cull is trusted
# for what it refuses: a task goes only when git can give all of it back.

commit_in_task() {
  local task="$1" repo="$2" push="$3"
  printf 'work\n' > "$SB_TASKS/$task/$repo/work.txt"
  git -C "$SB_TASKS/$task/$repo" add -A >/dev/null 2>&1
  git -C "$SB_TASKS/$task/$repo" commit -qm "work" >/dev/null 2>&1
  [[ -z "$push" ]] || git -C "$SB_TASKS/$task/$repo" push -q -u origin HEAD >/dev/null 2>&1
}

test_cull_removes_a_task_git_can_give_back() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  commit_in_task feat-one backend push

  local out
  out="$(iw cull --all -p myproj 2>&1)"
  assert_contains "it says what it culled" "Culled 1" "$out"
  assert_no_file "the task is gone" "$SB_TASKS/feat-one"
  # The branch is what makes it re-creatable, so it must survive.
  assert_ok "and the branch is still there" \
    git -C "$SB_REPOS/backend" rev-parse --verify feat/one
}

test_cull_keeps_a_task_with_uncommitted_work() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  commit_in_task feat-one backend push
  printf 'half done\n' > "$SB_TASKS/feat-one/backend/scratch.txt"

  local out
  out="$(iw cull --all -p myproj 2>&1)"
  assert_contains "the reason is named" "uncommitted changes in backend" "$out"
  assert_dir "and the task stays" "$SB_TASKS/feat-one"
}

test_cull_takes_commits_that_never_reached_a_remote() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  commit_in_task feat-one backend ""

  # Unpushed is not unsafe. rm keeps branches, so the commits are still in the
  # repo once the worktree is gone. Blocking on this sounded careful and was
  # merely wrong -- it kept most of a real project's tasks for a risk that does
  # not exist.
  iw cull -p myproj feat-one >/dev/null 2>&1
  assert_no_file "the task is culled" "$SB_TASKS/feat-one"
  assert_ok "and the branch still has the commit" \
    git -C "$SB_REPOS/backend" rev-parse --verify feat/one
  assert_contains "which is where the work went" "work" \
    "$(git -C "$SB_REPOS/backend" show --name-only --format= feat/one 2>&1)"
}

test_cull_keeps_a_task_with_files_that_were_never_committed() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  commit_in_task feat-one backend push
  # Written at the task root rather than inside a repo, so git never saw it.
  printf 'handoff\n' > "$SB_TASKS/feat-one/HANDOFF.md"

  local out
  out="$(iw cull --all -p myproj 2>&1)"
  assert_contains "the file is named" "HANDOFF.md was never committed" "$out"
  assert_dir "and the task stays" "$SB_TASKS/feat-one"
  assert_file "with the file intact" "$SB_TASKS/feat-one/HANDOFF.md"
}

test_cull_only_touches_its_own_project() {
  mk_repo backend
  iw feat/mine -r backend -p myproj >/dev/null 2>&1
  iw feat/theirs -r backend -p otherproj >/dev/null 2>&1
  commit_in_task feat-mine backend push
  commit_in_task feat-theirs backend push

  iw cull --all -p myproj >/dev/null 2>&1
  assert_no_file "its own task is culled" "$SB_TASKS/feat-mine"
  assert_dir "another project's task is untouched" "$SB_TASKS/feat-theirs"

  # And naming it explicitly is refused rather than quietly obeyed.
  assert_fails "a task from another project is refused" \
    iw cull -p myproj feat-theirs
  assert_contains "and says why" "not in project" \
    "$(iw cull -p myproj feat-theirs 2>&1)"
}

test_cull_needs_the_tasks_named_or_all() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  commit_in_task feat-one backend push

  # A master's tasks are mostly tasks it is still using, so taking the lot has
  # to be asked for rather than being what a bare command does.
  assert_fails "a bare cull is refused" iw cull -p myproj
  assert_contains "and says how to mean it" "pass --all" "$(iw cull -p myproj 2>&1)"
  assert_dir "nothing was culled" "$SB_TASKS/feat-one"

  iw cull -p myproj feat-one >/dev/null 2>&1
  assert_no_file "naming it works" "$SB_TASKS/feat-one"
}

test_cull_keeps_a_task_whose_agent_is_working() {
  command -v tmux >/dev/null 2>&1 || { printf '    skip (no tmux)\n'; return 0; }
  mk_repo backend
  WANT_TMUX=1 iw --detach feat/one -r backend -p myproj >/dev/null 2>&1
  commit_in_task feat-one backend push

  # Culling takes the window and whatever is running in it, and a clean worktree
  # says nothing about what an agent is part way through doing to it.
  tmux_t rename-window -t '=projects-myproj:feat-one' '*feat-one' 2>/dev/null ||
    tmux_t rename-window -t '=tasks:feat-one' '*feat-one' 2>/dev/null

  local out
  out="$(WANT_TMUX=1 iw cull -p myproj feat-one 2>&1)"
  assert_contains "the reason is named" "working in it right now" "$out"
  assert_dir "and the task stays" "$SB_TASKS/feat-one"
}

test_cull_dry_run_changes_nothing() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  commit_in_task feat-one backend push

  local out
  out="$(iw cull -n -p myproj 2>&1)"
  assert_contains "it says it is a dry run" "Dry run" "$out"
  assert_contains "and what it would cull" "would be culled" "$out"
  assert_dir "while the task is still there" "$SB_TASKS/feat-one"
}

test_cull_works_from_the_project_directory() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1
  commit_in_task feat-one backend push

  # Where a master sits, and where 'rm' refuses to run.
  iw_in "$SB_PROJECTS/myproj" cull feat-one >/dev/null 2>&1
  assert_no_file "the task is culled without naming the project" "$SB_TASKS/feat-one"
}

test_rm_still_refuses_from_the_project_directory() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # cull is the narrow opening; rm itself stays shut.
  assert_fails "rm is still refused there" \
    iw_in "$SB_PROJECTS/myproj" rm -f feat-one
  assert_contains "and points at cull" "iwork cull" \
    "$(iw_in "$SB_PROJECTS/myproj" rm -f feat-one 2>&1)"
}

# --- runner -------------------------------------------------------------------

echo "iwork tests  ($IWORK_SRC)"
echo ""

trap 'stop_watchdog' EXIT
start_watchdog

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  run_test "$t"
done

stop_watchdog
echo ""
if (( FAIL > 0 )); then
  echo "FAILED: $FAIL assertion(s), $PASS passed"
  echo ""
  printf '%s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
echo "OK: $PASS assertions passed"
