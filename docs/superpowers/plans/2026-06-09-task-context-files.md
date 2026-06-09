# iwork Task Context Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write a scope-setting `CLAUDE.md` and `AGENTS.md` into each iwork task folder at creation/park, rendered from a user-editable template.

**Architecture:** One new bash function `write_task_context` in the single `iwork` script, called from the two existing task-setup call sites (main creation path and end of `park_current_repo`) right alongside `open_task_window`. A new global for the template path, a new `IWORK_NO_CONTEXT` env/flag opt-out, plus usage/completion updates.

**Tech Stack:** bash 3.2-compatible shell script (macOS). No new dependencies — pure bash string substitution, no template engine, no python.

**Spec:** `docs/superpowers/specs/2026-06-09-task-context-files-design.md`

---

## Important context for the implementer

- The entire tool is ONE executable bash script: `/Users/sbk/dev/igloo/iwork/iwork` (working dir `/Users/sbk/dev/igloo/iwork`, branch `main`). No test suite; verification is manual against a temp `IGLOO_DIR` and a temp `HOME`/`IWORK_CONTEXT_TEMPLATE` so the real `~/.config/iwork/` is never touched.
- macOS ships bash 3.2. Do NOT use associative arrays, `${var,,}`, `readarray`, etc. The script is bash-3.2-clean; keep it so. Verify with BOTH `bash -n` and `/bin/bash -n`.
- The script uses `set -euo pipefail`. Any command that may fail must be guarded (`|| true`, `|| warn ...`, `if ...`). A `printf > file` that fails (bad path/permission) would abort under `set -e`, so writes are guarded.
- The script already uses a `warn()` helper (stderr, non-fatal) and a `die()` helper (stderr, exit 1). Context generation is best-effort: use `warn`, never `die`.
- Existing relevant globals near the top: `IGLOO_DIR` (line 4, env-overridable), `WORKTREES_DIR="$IGLOO_DIR/AAWORKTREES"` (line 5), `SELF_PATH` (line 6), `TASKS_SESSION` (line 7), `IWORK_NO_TMUX=""` (line 8).
- Existing call sites that this mirrors: `open_task_window "$folder_name" claude` appears at the end of `park_current_repo` (line ~359) and at the very end of the script after the main `create_worktrees` (line ~1109).
- The leading-flag parse block is at lines ~973-979 (`if [[ "${1:-}" == "--no-tmux" ]]; then ... fi`), between the empty-args `usage 0` check and the main `case "${1:-}" in` dispatch.
- The default-template seeding mirrors how `install_claude_hooks` creates `~/.claude/` — create the parent dir with `mkdir -p` then write.
- Per the user's global rules: commit messages are plain `type: description`, NO emoji, NO Co-Authored-By trailers of any kind.

## Manual test harness (used by several tasks)

Run in a normal terminal. Uses a throwaway `HOME` so the default template lands in a temp `~/.config/iwork/`, and a temp `IGLOO_DIR`.

**Setup:**

```bash
IWORK=/Users/sbk/dev/igloo/iwork/iwork
TD="$(cd "$(mktemp -d)" && pwd -P)"
export HOME_BAK="$HOME"
mkdir -p "$TD/home" "$TD/igloo/repo-a" "$TD/igloo/repo-b"
git init -q "$TD/igloo/repo-a"; git -C "$TD/igloo/repo-a" commit -q --allow-empty -m init
git init -q "$TD/igloo/repo-b"; git -C "$TD/igloo/repo-b" commit -q --allow-empty -m init
run_iwork() { env HOME="$TD/home" IGLOO_DIR="$TD/igloo" IWORK_NO_TMUX=1 "$IWORK" "$@"; }
```

Notes:
- `IWORK_NO_TMUX=1` keeps these filesystem tests free of tmux side effects; context generation is independent of tmux, so this is the right isolation.
- `HOME="$TD/home"` means the default template seeds at `$TD/home/.config/iwork/task-context.md.tmpl`.

**Teardown:**

```bash
rm -rf "$TD"
```

---

### Task 1: write_task_context function + globals + call-site wiring

**Files:**
- Modify: `iwork` — globals after line 8; new function before the dispatch (near `open_task_window`, ~line 824); two call sites (~line 359 in `park_current_repo`, ~line 1109 main path)

- [ ] **Step 1: Add globals**

After line 8 (`IWORK_NO_TMUX=""`), add:

```bash
IWORK_NO_CONTEXT=""
CONTEXT_TEMPLATE="${IWORK_CONTEXT_TEMPLATE:-$HOME/.config/iwork/task-context.md.tmpl}"
```

- [ ] **Step 2: Add the write_task_context function**

Insert immediately BEFORE the `open_task_window() {` line (~824):

```bash
DEFAULT_CONTEXT_TEMPLATE='# Task: {{TASK}}

You are working in an iwork task directory. It contains git worktrees of
the repositories relevant to this task, all on branch `{{BRANCH}}`:

{{REPOS}}

## Scope

- Stay within this task directory. Do not read, edit, or run commands in
  repositories outside the worktrees listed above — they are scoped here
  deliberately.
- Each subdirectory is a real git worktree; commit within it as normal.
- Each repo may have its own CLAUDE.md / AGENTS.md — read it before working
  in that repo and follow its conventions.'

seed_context_template() {
  local template_dir=""

  [[ -f "$CONTEXT_TEMPLATE" ]] && return 0

  template_dir="$(dirname "$CONTEXT_TEMPLATE")"
  if ! mkdir -p "$template_dir" 2>/dev/null; then
    warn "could not create template directory $template_dir"
    return 1
  fi
  if ! printf '%s\n' "$DEFAULT_CONTEXT_TEMPLATE" > "$CONTEXT_TEMPLATE" 2>/dev/null; then
    warn "could not write default template $CONTEXT_TEMPLATE"
    return 1
  fi
  return 0
}

write_task_context() {
  local folder="$1"
  local branch="$2"
  local folder_path="$WORKTREES_DIR/$folder"
  local template=""
  local repos_list=""
  local rendered=""
  local child=""
  local target=""

  [[ -n "$IWORK_NO_CONTEXT" ]] && return 0
  [[ -d "$folder_path" ]] || return 0

  seed_context_template || return 0

  template="$(cat "$CONTEXT_TEMPLATE" 2>/dev/null || true)"
  [[ -n "$template" ]] || { warn "task context template is empty: $CONTEXT_TEMPLATE"; return 0; }

  for child in "$folder_path"/*; do
    [[ -d "$child" ]] || continue
    if [[ -n "$repos_list" ]]; then
      repos_list="$repos_list
${child##*/}"
    else
      repos_list="${child##*/}"
    fi
  done

  rendered="$template"
  rendered="${rendered//\{\{TASK\}\}/$folder}"
  rendered="${rendered//\{\{BRANCH\}\}/$branch}"
  rendered="${rendered//\{\{REPOS\}\}/$repos_list}"

  for target in "$folder_path/CLAUDE.md" "$folder_path/AGENTS.md"; do
    [[ -e "$target" ]] && continue
    printf '%s\n' "$rendered" > "$target" 2>/dev/null || warn "could not write $target"
  done
}
```

Design notes (do not deviate):
- Substitution order is TASK, then BRANCH, then REPOS, so a repo or branch name can never reintroduce a placeholder token.
- `${rendered//\{\{REPOS\}\}/$repos_list}` correctly substitutes a multi-line value — bash parameter expansion handles newlines in the replacement.
- `${child##*/}` is the basename of each worktree subdir (e.g. `repo-a--feat-x`). The task root contains only worktree subdirs at this point.
- Every external action (mkdir, both writes, cat) is guarded; the function always returns 0 on the happy path and on any soft failure, so it can never abort worktree setup under `set -e`.
- `[[ -n "$IWORK_NO_CONTEXT" ]] && return 0` is the env opt-out; the `--no-context` flag (Task 2) sets this global.

- [ ] **Step 3: Wire into the main creation path**

At the end of the script (~line 1108-1109), currently:

```bash
create_worktrees "$branch" "$folder_name" "$branch_slug" "${repos[@]}"
open_task_window "$folder_name" claude
```

becomes:

```bash
create_worktrees "$branch" "$folder_name" "$branch_slug" "${repos[@]}"
write_task_context "$folder_name" "$branch"
open_task_window "$folder_name" claude
```

- [ ] **Step 4: Wire into park_current_repo**

At the end of `park_current_repo` (~line 355-360), currently:

```bash
  echo ""
  echo "Done! Worktree parked at:"
  echo "  $wt_path"

  open_task_window "$folder_name" claude
}
```

becomes:

```bash
  echo ""
  echo "Done! Worktree parked at:"
  echo "  $wt_path"

  write_task_context "$folder_name" "$branch"
  open_task_window "$folder_name" claude
}
```

Note: `branch` is a local already set in `park_current_repo` (the branch being parked) — confirm by reading the function; it is set near the top via `branch="$(current_branch_name "$repo_root")"`.

- [ ] **Step 5: Syntax check**

```bash
bash -n /Users/sbk/dev/igloo/iwork/iwork && echo OK
/bin/bash -n /Users/sbk/dev/igloo/iwork/iwork && echo OK32
```

Expected: `OK`, `OK32`.

- [ ] **Step 6: Verify creation, template seeding, substitution**

Run the harness **Setup**, then:

```bash
# Default template does not exist yet
ls "$TD/home/.config/iwork/task-context.md.tmpl" 2>&1
# Expected: No such file or directory

run_iwork feat/ctx-test -r repo-a repo-b
# (worktrees created under $TD/igloo/AAWORKTREES/feat-ctx-test/)

# Default template was seeded
cat "$TD/home/.config/iwork/task-context.md.tmpl" | head -1
# Expected: # Task: {{TASK}}

# Both context files exist and are identical
diff "$TD/igloo/AAWORKTREES/feat-ctx-test/CLAUDE.md" "$TD/igloo/AAWORKTREES/feat-ctx-test/AGENTS.md" && echo IDENTICAL
# Expected: IDENTICAL

# Substitution is correct
cat "$TD/igloo/AAWORKTREES/feat-ctx-test/CLAUDE.md"
# Expected: title "# Task: feat-ctx-test"; branch line shows `feat/ctx-test`;
# the {{REPOS}} block lists:
#   repo-a--feat-ctx-test
#   repo-b--feat-ctx-test
# and NO literal {{...}} placeholders remain
grep -c '{{' "$TD/igloo/AAWORKTREES/feat-ctx-test/CLAUDE.md"
# Expected: 0
```

- [ ] **Step 7: Verify never-overwrite**

Pre-create the task folder (folder name = branch slug) with a hand-edited
`CLAUDE.md` and no `AGENTS.md`, then run creation over it. `create_worktrees`
uses `mkdir -p`, so an existing folder is fine. Continue in the same harness:

```bash
mkdir -p "$TD/igloo/AAWORKTREES/feat-keep"
printf 'HAND EDITED\n' > "$TD/igloo/AAWORKTREES/feat-keep/CLAUDE.md"

run_iwork feat/keep -r repo-a

# Existing CLAUDE.md is preserved (not overwritten)
cat "$TD/igloo/AAWORKTREES/feat-keep/CLAUDE.md"
# Expected: HAND EDITED

# AGENTS.md was absent, so it IS written
grep -q 'Task: feat-keep' "$TD/igloo/AAWORKTREES/feat-keep/AGENTS.md" && echo AGENTS-WRITTEN
# Expected: AGENTS-WRITTEN

# add-repo does NOT generate context (spec: add-repo unchanged)
rm -f "$TD/igloo/AAWORKTREES/feat-keep/AGENTS.md"
run_iwork add-repo feat-keep -r repo-b
ls "$TD/igloo/AAWORKTREES/feat-keep/AGENTS.md" 2>&1
# Expected: No such file or directory (add-repo did not regenerate)
```

- [ ] **Step 8: Verify IWORK_NO_CONTEXT and custom template**

```bash
# Opt-out via env
env HOME="$TD/home" IGLOO_DIR="$TD/igloo" IWORK_NO_TMUX=1 IWORK_NO_CONTEXT=1 "$IWORK" feat/no-ctx -r repo-a
ls "$TD/igloo/AAWORKTREES/feat-no-ctx/CLAUDE.md" 2>&1
# Expected: No such file or directory

# Custom template honored and not overwritten
printf 'CUSTOM {{TASK}} on {{BRANCH}}\n' > "$TD/custom.tmpl"
env HOME="$TD/home" IGLOO_DIR="$TD/igloo" IWORK_NO_TMUX=1 IWORK_CONTEXT_TEMPLATE="$TD/custom.tmpl" "$IWORK" feat/custom -r repo-a
cat "$TD/igloo/AAWORKTREES/feat-custom/CLAUDE.md"
# Expected: CUSTOM feat-custom on feat/custom
cat "$TD/custom.tmpl"
# Expected: still 'CUSTOM {{TASK}} on {{BRANCH}}' (template not modified)
```

Run the harness **Teardown**.

- [ ] **Step 9: Commit**

```bash
git add iwork
git commit -m "feat: generate task context files (CLAUDE.md/AGENTS.md) on creation and park"
```

### Task 2: --no-context flag parsing

**Files:**
- Modify: `iwork` — the leading-flag parse block (~lines 973-979)

- [ ] **Step 1: Generalize the leading-flag parse to handle both flags in any order**

Currently (~973-979):

```bash
if [[ "${1:-}" == "--no-tmux" ]]; then
  IWORK_NO_TMUX=1
  shift
  if [[ $# -eq 0 ]]; then
    usage 1
  fi
fi
```

Replace with:

```bash
while [[ "${1:-}" == "--no-tmux" || "${1:-}" == "--no-context" ]]; do
  case "$1" in
    --no-tmux) IWORK_NO_TMUX=1 ;;
    --no-context) IWORK_NO_CONTEXT=1 ;;
  esac
  shift
  if [[ $# -eq 0 ]]; then
    usage 1
  fi
done
```

This accepts `--no-tmux`, `--no-context`, or both (in either order) as leading global flags, and preserves the existing "flag with no following command → usage 1" behavior.

- [ ] **Step 2: Syntax check**

```bash
bash -n /Users/sbk/dev/igloo/iwork/iwork && echo OK
/bin/bash -n /Users/sbk/dev/igloo/iwork/iwork && echo OK32
```

Expected: `OK`, `OK32`.

- [ ] **Step 3: Verify flag behavior and independence from --no-tmux**

Run the harness **Setup**, then:

```bash
# --no-context skips generation for one invocation
run_iwork --no-context feat/flag-a -r repo-a
ls "$TD/igloo/AAWORKTREES/feat-flag-a/CLAUDE.md" 2>&1
# Expected: No such file or directory

# --no-tmux alone still generates context (independence)
run_iwork feat/flag-b -r repo-a
ls "$TD/igloo/AAWORKTREES/feat-flag-b/CLAUDE.md"
# Expected: path printed (file exists)

# Both flags together: no context, and (separately) no tmux
env HOME="$TD/home" IGLOO_DIR="$TD/igloo" "$IWORK" --no-tmux --no-context feat/flag-c -r repo-a
ls "$TD/igloo/AAWORKTREES/feat-flag-c/CLAUDE.md" 2>&1
# Expected: No such file or directory

# Order-independence: --no-context --no-tmux
env HOME="$TD/home" IGLOO_DIR="$TD/igloo" "$IWORK" --no-context --no-tmux feat/flag-d -r repo-a
ls "$TD/igloo/AAWORKTREES/feat-flag-d/CLAUDE.md" 2>&1
# Expected: No such file or directory

# Bare flag with no command still errors
env HOME="$TD/home" IGLOO_DIR="$TD/igloo" "$IWORK" --no-context; echo "RC=$?"
# Expected: usage text, RC=1
```

Run the harness **Teardown**.

- [ ] **Step 4: Commit**

```bash
git add iwork
git commit -m "feat: add --no-context flag to skip task context generation"
```

### Task 3: usage text and completions

**Files:**
- Modify: `iwork:12-18` (usage Usage lines), the Options block in `usage()`, `iwork:623` and `iwork:628` (bash completion word lists), the zsh `_values` block (~line 720-727)

- [ ] **Step 1: Add --no-context to the usage Usage lines**

In `usage()`, the Usage lines currently read `iwork [--no-tmux] <branch-name> ...` etc. Update the same lines that carry `[--no-tmux]` to carry `[--no-tmux] [--no-context]`. Specifically replace these lines:

```
Usage: iwork [--no-tmux] <branch-name> -r <repo1> [repo2 ...]
       iwork add-repo <folder-name-in-AAWORKTREES> -r <repo1> [repo2 ...]
       iwork [--no-tmux] park <folder-name-in-AAWORKTREES>
       iwork [--no-tmux] list
       iwork [--no-tmux] cd <folder-name-in-AAWORKTREES>
       iwork [--no-tmux] claude <folder-name-in-AAWORKTREES> [claude-args...]
       iwork [--no-tmux] codex <folder-name-in-AAWORKTREES> [codex-args...]
```

with:

```
Usage: iwork [--no-tmux] [--no-context] <branch-name> -r <repo1> [repo2 ...]
       iwork add-repo <folder-name-in-AAWORKTREES> -r <repo1> [repo2 ...]
       iwork [--no-tmux] [--no-context] park <folder-name-in-AAWORKTREES>
       iwork [--no-tmux] list
       iwork [--no-tmux] cd <folder-name-in-AAWORKTREES>
       iwork [--no-tmux] claude <folder-name-in-AAWORKTREES> [claude-args...]
       iwork [--no-tmux] codex <folder-name-in-AAWORKTREES> [codex-args...]
```

(Only creation and `park` actually generate context, so only those two gain `[--no-context]`; the flag is harmless but meaningless on the others.)

- [ ] **Step 2: Add a context paragraph and the --no-context option to usage()**

Find the tmux explanatory paragraph in `usage()` (it begins "Inside tmux, each task maps to a window..."). Immediately AFTER that paragraph's blank line, add:

```
On creation and park, iwork writes CLAUDE.md and AGENTS.md into the task
folder from a template (~/.config/iwork/task-context.md.tmpl, override with
IWORK_CONTEXT_TEMPLATE), seeding a default template on first use. Existing
files are never overwritten.
```

In the `Options:` block, currently:

```
  --no-tmux  Skip all tmux window handling (must be the first argument)
  -r         Repos to create worktrees for (required, at least one)
  -h         Show this help
```

replace with:

```
  --no-tmux     Skip all tmux window handling (leading flag)
  --no-context  Skip writing CLAUDE.md/AGENTS.md task context (leading flag)
  -r            Repos to create worktrees for (required, at least one)
  -h            Show this help
```

- [ ] **Step 3: Update the bash completion word lists**

Line ~623:

```bash
    COMPREPLY=( $(compgen -W "add-repo park list cd claude codex install-hooks --no-tmux -h --help --completion" -- "$cur") )
```

becomes:

```bash
    COMPREPLY=( $(compgen -W "add-repo park list cd claude codex install-hooks --no-tmux --no-context -h --help --completion" -- "$cur") )
```

Line ~628:

```bash
    COMPREPLY=( $(compgen -W "-r -h --help --completion --no-tmux" -- "$cur") )
```

becomes:

```bash
    COMPREPLY=( $(compgen -W "-r -h --help --completion --no-tmux --no-context" -- "$cur") )
```

- [ ] **Step 4: Update the zsh completion command list**

In `print_zsh_completion`'s `_values 'command'` block, after the `'--no-tmux[skip tmux window handling]' \` line add:

```bash
      '--no-context[skip writing task context files]' \
```

- [ ] **Step 5: Syntax check and eyeball**

```bash
bash -n /Users/sbk/dev/igloo/iwork/iwork && echo OK
/bin/bash -n /Users/sbk/dev/igloo/iwork/iwork && echo OK32
/Users/sbk/dev/igloo/iwork/iwork --help
/Users/sbk/dev/igloo/iwork/iwork --completion bash > /tmp/c.bash && bash -n /tmp/c.bash && echo BASH-OK
/Users/sbk/dev/igloo/iwork/iwork --completion zsh > /tmp/c.zsh && zsh -n /tmp/c.zsh && echo ZSH-OK
grep -c -- '--no-context' /tmp/c.bash
# Expected: 2
grep -c -- '--no-context' /tmp/c.zsh
# Expected: 1
```

Expected: `OK`, `OK32`, full help text showing the new Usage lines, context paragraph, and both `--no-*` options; `BASH-OK`; `ZSH-OK`; counts 2 and 1.

- [ ] **Step 6: Commit**

```bash
git add iwork
git commit -m "docs: document task context files and --no-context in usage and completions"
```

### Task 4: Real-environment smoke test (with the user)

Checklist for the user's actual environment (branch already merged to main after this work):

- [ ] **Step 1: Re-source shell integration** — `source <(iwork --completion zsh)`.
- [ ] **Step 2: Create a throwaway task** — `iwork test/ctx-smoke -r email-templates`. Expect `~/.config/iwork/task-context.md.tmpl` to appear (first use), and `CLAUDE.md` + `AGENTS.md` in `~/dev/igloo/AAWORKTREES/test-ctx-smoke/` with the task name, branch, and `email-templates--test-ctx-smoke` in the repo list.
- [ ] **Step 3: Confirm the agent sees it** — in the task window's claude pane, the scope context should be in effect (ask claude what task it's working on / its scope).
- [ ] **Step 4: Edit the template** — tweak `~/.config/iwork/task-context.md.tmpl`, create another task, confirm the new wording flows through.
- [ ] **Step 5: Clean up** — exit claude, kill the window, remove the worktree and branch, `rm -rf ~/dev/igloo/AAWORKTREES/test-ctx-smoke`.
