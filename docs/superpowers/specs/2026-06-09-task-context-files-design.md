# iwork task context files — design

Date: 2026-06-09
Status: approved pending review

## Problem

An `iwork` task folder under `AAWORKTREES/<task>/` holds git worktrees of several
repositories, all on one branch, scoped together deliberately. When an agent
(claude or codex) starts in that folder it has no standing notion of that scope —
nothing stops it from wandering into unrelated repos, and nothing tells it the
subdirectories are worktrees that each carry their own conventions.

## Goal

Give every agent session that starts in a task folder a persistent, scope-setting
context file, rendered from a user-editable template, written once at task setup.

## Decisions

- **Mechanism:** generated `CLAUDE.md` and `AGENTS.md` at the task folder root
  (not a startup prompt). Same content in both files.
- **Trigger:** task creation (`iwork <branch> -r ...`) and `park`, after worktrees
  are in place. Not `add-repo`.
- **Template:** `~/.config/iwork/task-context.md.tmpl`, override via
  `IWORK_CONTEXT_TEMPLATE`. Written with a default if missing, then rendered.
- **Never overwrite:** each target file is written only if absent.
- **Independent of tmux:** runs as filesystem work, so `--no-tmux` and non-tmux
  invocations still get the files. Skippable via `IWORK_NO_CONTEXT=1` or
  `--no-context`.
- **Best-effort:** template/write failures warn but never abort worktree setup.

## 1. Placement and rationale

The task folder root (`$WORKTREES_DIR/<task>/`) is an untracked container; only its
subdirectories are git worktrees. Writing `CLAUDE.md`/`AGENTS.md` at the root means:

- The agent, launched in the task root, loads them as standing context.
- They are never committed into any repo (the root is not a git repo).
- They do not collide with a repo's own `CLAUDE.md`/`AGENTS.md` inside the worktree
  subdirectories.

Both files get identical content. Claude reads `CLAUDE.md`; codex reads `AGENTS.md`.

## 2. Template

Location: `${IWORK_CONTEXT_TEMPLATE:-$HOME/.config/iwork/task-context.md.tmpl}`.

On generation, if the template file does not exist, iwork creates the parent
directory (like `install-hooks` does for settings.json) and writes the default
template below, then renders from it. This makes the feature work out of the box
while leaving the template fully user-editable thereafter.

Placeholders (plain string substitution, no template engine):

- `{{TASK}}` — task folder name.
- `{{BRANCH}}` — the branch all worktrees are on.
- `{{REPOS}}` — newline-separated list of the worktree subdirectory names in the
  task folder.

Default template content:

```markdown
# Task: {{TASK}}

You are working in an iwork task directory. It contains git worktrees of
the repositories relevant to this task, all on branch `{{BRANCH}}`:

{{REPOS}}

## Scope

- Stay within this task directory. Do not read, edit, or run commands in
  repositories outside the worktrees listed above — they are scoped here
  deliberately.
- Each subdirectory is a real git worktree; commit within it as normal.
- Each repo may have its own CLAUDE.md / AGENTS.md — read it before working
  in that repo and follow its conventions.
```

## 3. Generation flow

A new function renders the template and writes both files. It is called from the
main creation path (after `create_worktrees`) and from the end of
`park_current_repo` — the same two call sites as `open_task_window`, and it runs
before/independent of the tmux window opening.

Steps:

1. Return early if `IWORK_NO_CONTEXT` is set or `--no-context` was given.
2. Resolve the template path; if missing, create `~/.config/iwork/` and write the
   default template.
3. Read the template; compute `{{REPOS}}` by listing the task folder's worktree
   subdirectories (the `*--*` worktree dirs already created), one name per line.
4. Substitute the three placeholders.
5. For each of `CLAUDE.md`, `AGENTS.md` in the task root: write only if the file
   does not already exist.

`{{REPOS}}` derivation: for creation, the repo set is known; for park, list the
existing worktree subdirectories of the task folder. Listing the folder's
subdirectories works for both and is the single implementation.

## 4. Flag and env handling

- `IWORK_NO_CONTEXT=1` — skip generation (env, for permanent opt-out).
- `--no-context` — skip generation for one invocation. Parsed as a global flag
  alongside `--no-tmux` (both may appear; order among themselves not significant).
- Independent of `--no-tmux`: `iwork --no-tmux <branch> -r ...` still writes the
  context files; `iwork --no-context <branch> -r ...` still opens the tmux window.

## 5. Error handling

Consistent with the existing tmux code — best-effort, never fatal:

- Failure to read the template, create the config dir, or write a target file emits
  a `warn` and continues; the worktree setup result is still reported as success.
- Never-overwrite is a plain existence check before each write; a pre-existing
  hand-edited file is left untouched with no warning.

## 6. Testing

Manual verification (no test suite), against a temp `IGLOO_DIR` and a temp
`IWORK_CONTEXT_TEMPLATE`/`HOME` so the real `~/.config/iwork/` is never touched:

- Default template is created on first run when absent; subsequent runs reuse it.
- Creation writes `CLAUDE.md` and `AGENTS.md` at the task root with `{{TASK}}`,
  `{{BRANCH}}`, and the repo list correctly substituted.
- Both files identical.
- Pre-existing `CLAUDE.md` is not overwritten (hand edit survives); `AGENTS.md`
  still written if it was absent.
- `park` produces the files with the parked repo listed.
- `IWORK_NO_CONTEXT=1` and `--no-context` each skip generation.
- `--no-tmux` still generates; `--no-context` still opens the tmux window.
- A custom `IWORK_CONTEXT_TEMPLATE` is honored and not overwritten.

## Out of scope

- No startup-prompt variant.
- No persona/preferences block in the default template (user can add their own).
- No regeneration/sync command; `add-repo` does not refresh the files.
- No per-repo file generation.
