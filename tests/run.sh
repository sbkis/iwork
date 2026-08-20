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
  env -u TMUX \
    HOME="$SB_HOME" \
    GIT_CONFIG_GLOBAL="$SB_HOME/.gitconfig" \
    TMUX_TMPDIR="$SB/tmux" \
    IWORK_CONFIG_FILE="$SB/config" \
    IWORK_REPO_DIR="$SB_REPOS" \
    IWORK_TASKS_DIR="$SB_TASKS" \
    IWORK_PROJECTS_DIR="$SB_PROJECTS" \
    IWORK_CONTEXT_TEMPLATE="$SB_HOME/.config/iwork/task-context.md.tmpl" \
    IWORK_PROJECT_TEMPLATE="$SB_HOME/.config/iwork/project-context.md.tmpl" \
    IWORK_NO_TMUX="${WANT_TMUX:+}${WANT_TMUX:-1}" \
    IWORK_ASSUME_YES="${ASSUME_YES-1}" \
    "$IWORK_SRC" "$@"
}

# Same, but from inside a task directory, which is how agents will call it.
iw_in() {
  local dir="$1"
  shift
  ( cd "$dir" && iw "$@" )
}

tmux_t() { env -u TMUX TMUX_TMPDIR="$SB/tmux" tmux -f /dev/null "$@"; }
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
    raw="$( cd "$SB_TASKS/feat-one" && rg ZORBLAX 2>/dev/null )"
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

test_park_wrapper_forwards_flags() {
  # The sourced wrapper used to drop everything after the task name, which
  # would silently swallow -p.
  local out
  out="$(iw --completion bash 2>&1)"
  assert_contains "wrapper forwards park args" 'park "$folder" "$@"' "$out"
  out="$(iw --completion zsh 2>&1)"
  assert_contains "zsh wrapper forwards park args" 'park "$folder" "$@"' "$out"
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

test_template_forbids_direct_project_access() {
  mk_repo backend
  iw feat/one -r backend -p myproj >/dev/null 2>&1

  # The scope rule stays absolute; the CLI is the only way in.
  assert_grep "block forbids direct access" "do not read, edit, search" \
    "$SB_TASKS/feat-one/CLAUDE.md"
  assert_grep "block offers cat instead" "iwork project cat" \
    "$SB_TASKS/feat-one/CLAUDE.md"
  assert_no_grep "block no longer claims .project is in scope" "is in scope" \
    "$SB_TASKS/feat-one/CLAUDE.md"
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
  assert_contains "tells the agent not to touch .project" ".project" "$out"
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

test_install_hooks_registers_every_event() {
  command -v python3 >/dev/null 2>&1 || { printf '    skip (no python3)\n'; return 0; }
  iw install-hooks "$SB/settings.json" >/dev/null 2>&1

  assert_file "settings written" "$SB/settings.json"
  assert_eq "every event registered" "" "$(python3 - "$SB/settings.json" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1])).get("hooks", {})
want = ["UserPromptSubmit", "Stop", "Notification", "SessionStart", "PreCompact", "PostToolUse"]
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
  assert_eq "install-hooks is idempotent" "6" "$count"
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
