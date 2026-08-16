# git-worktrees

Idea-workspace tooling built on `git worktree`. The unit of work is an **idea**,
not a repository: one idea can span multiple repos, and it gets the same branch
name and one worktree per participating repo.

```text
            IDEA
             │
     ┌───────┼────────┐
     │       │        │
explorer  data  ramayana
     │       │        │
 worktree  worktree  worktree
     │       │        │
  branch   branch   branch
```

This keeps parallel ideas strictly isolated — each lives in its own worktree
under its own branch, so none can trample another. It's a thin, defensive Fish
layer over Git: Git remains the state machine; the registry is human-readable
metadata; nothing is fetched, pushed, or committed automatically.

## Layout

```
$__wt_github_home/<repo>            main clones   (default: ~/github)
$__wt_worktree_home/<repo>/<idea>   worktrees     (default: ~/git-worktrees)
$__wt_worktree_home/WORKTREE-GROUPS named repo groups
```

Both homes are configurable. `configure.sh` writes an override that loads
before the functions file; `worktrees.fish` itself ships with defaults only.

## Requirements

- **fish ≥ 3.3** (uses the `path` builtin) and **git ≥ 2.31** (uses
  `--path-format=absolute`).

The tooling **fast-fails** on unsupported environments rather than failing
cryptically at first use:

- `worktrees.fish` refuses to load (`return 1`) with a clear "too old" message
  if the running fish or git is below the minimum.
- `configure.sh` / `install.sh` check versions up front and refuse before
  touching anything if fish or git is missing or too old.

## Install

```sh
git clone <this repo> ~/github/git-worktrees
cd ~/github/git-worktrees

./configure.sh   # interactive: homes + seed WORKTREE-GROUPS
./install.sh     # symlink worktrees.fish + set the `git plan` alias
```

Then reload fish (`source ~/.config/fish/conf.d/worktrees.fish` or open a new
shell). Re-running `./install.sh` is safe; `git pull` in the repo updates the
tooling in place (worktrees.fish is symlinked).

## Tests

`./test.sh` runs an automated lifecycle test against throwaway repos in a temp
dir (no real repos touched, cleans up after). It covers: start / idempotent
restart / multi-repo / missing-repo preflight / invalid-idea / bogus-destination
/ go / `git plan` matching / merge dirty-main and wrong-branch refusal /
coordinated merge / stop keeps branch / stop refuses dirty without `--force` /
resume / rm / and the environment fast-fail guards. Exits nonzero if any test
fails.

```sh
./test.sh
```

## Commands

Repo selection is mutually exclusive and defaults to the current repo only:

- `--repos=A,B,C` — one-off repo set for this invocation (ephemeral).
- `-g NAME` — a named group from `WORKTREE-GROUPS`.
- `--save NAME` — with `--repos`, persist the set as group `NAME`.
  (`--repos` + `-g` together is an error; `--save` without `--repos` is an
  error.)

| Command | Action |
|---|---|
| `worktree-start [--repos=A,B,C \| -g NAME] [--save NAME] <idea>` | Create/resume the worktree(s), cd in, run `npm install` (if `package.json` present), print paired dirs. Two-phase: validates the whole repo set before creating anything. |
| `worktree-go <idea>` | cd into this repo's worktree, show status + registry row. |
| `worktree-merge [--repos=A,B,C \| -g NAME] <idea>` | Coordinated rebase-onto-local-`main` then `--ff-only` merge into each main. No push. Not a cross-repo transaction. |
| `worktree-stop [--repos=A,B,C \| -g NAME] [--force] <idea>` | Park: remove the worktree dir, keep the branch. Refuses if dirty unless `--force`. |
| `worktree-rm [--repos=A,B,C \| -g NAME] [--force] <idea>` | Tear down: remove the worktree, then delete the branch (safe-first; confirms before `-D`). |
| `worktree-list` | Global recall: every worktree + registry across all repos. |
| `git plan` | Show this worktree's registry row from `main:WORKTREES.md`. |

`<idea>` must satisfy `<idea> == branch == one directory component` (validated;
no `/`, no leading `-`, must be a valid Git ref). `main` always means the
**local** `main` branch — the tool never fetches or pushes.

## Lifecycle

```text
author plan -> register (WORKTREES.md) -> worktree-start ->
develop/commit -> worktree-merge -> worktree-stop (park) | worktree-rm (teardown)
-> update WORKTREES.md
```

- `worktree-start` is idempotent: existing worktree -> just cd; parked branch ->
  re-attach; missing -> create off `main`.
- `worktree-stop` keeps the branch (resume later with `start`); `worktree-rm`
  deletes it (done forever).
- `worktree-merge` is *coordinated, not transactional*: preflight all repos,
  rebase all branches, then fast-forward all mains. On a phase-1 failure no
  main is merged, but some idea branches may already have been rebased.

## Registry (`WORKTREES.md`)

Each repo keeps a root `WORKTREES.md` — a **human-maintained** registry (never
auto-edited). The tooling prints reminders at lifecycle boundaries. The Status
column uses `active | parked | merged | abandoned`.

## WORKTREE-GROUPS

```
default: grantha-data grantha-explorer
ramayana: grantha-data grantha-explorer ramayana
```

Group names are `[a-z0-9][a-z0-9-]*` (validated; first char must be
alphanumeric, so no leading dash). Repos are alphabetized on `--save`.

## Known limitations

- **Install is npm-only** — gated on `package.json`; pnpm/yarn/bun repos are
  not auto-installed yet (TODO).
- **`main` is local** — keeping it current with `origin` is your job.
- **Cross-repo operations are best-effort sequential** — `stop`/`rm` abort on a
  dirty repo in the middle; each per-repo step is individually safe.
- **`git plan`** relies on POSIX `sh` for the `!` alias (backticks escaped); the
  escaping is verified sound, but host `/bin/sh` variance is a residual risk.

## Future work

Idea-centric `worktree-list` dashboard; package-manager detection; non-mutating
stale-`main` warning; interactive skip/stash for mid-set stop/rm. Deliberately
excluded: auto-commit/push/PR, state databases, daemons — Git stays the state
machine.
