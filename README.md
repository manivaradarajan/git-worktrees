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

## Contents

This repo hosts two tools:

| Tool | What it is | Where |
|---|---|---|
| worktrees (fish) | Idea-workspace tooling on `git worktree` | `worktrees.fish`, `install.sh`, `configure.sh` |
| opencode model-routing | DeepSeek Pro/Flash routing alarm + contract | `opencode/` |

## Layout

```
$__wt_github_home/<repo>            main clones   (default: ~/github)
$__wt_worktree_home/<idea>/<repo>   worktrees     (default: ~/git-worktrees)
$__wt_venv_home/<idea>              shared venv   (one per idea)
$__wt_worktree_home/WORKTREE-GROUPS named repo groups
```

Both homes are configurable. `configure.sh` writes an override that loads
before the functions file; `worktrees.fish` itself ships with defaults only.
`$__wt_venv_home` (default `$__wt_worktree_home/.venvs`) is where each idea's
**shared Python venv** lives — see *Shared Python venv* below. Any directory
with its own `.venv` (typically a **main clone** like `~/github/grantha-data`)
gets that venv auto-activated on cd — see *Repo-local .venv*.

Every command works from **any directory**: repos are located under
`$__wt_github_home`, ideas under `$__wt_worktree_home/<idea>`, so you never have
to `cd` into a repo first. Missing arguments are prompted for when stdin is
interactive (see *Commands*).

## Requirements

- **fish ≥ 3.3** (uses the `path` builtin) and **git ≥ 2.31** (uses
  `--path-format=absolute`).
- **`python3`** is required when any participating repo has a Python manifest
  (`pyproject.toml` or `requirements.txt`). **`uv`** is optional: when present
  it creates/installs the venv (fast, re-syncs every start); without it the
  tool falls back to `python3 -m venv` + pip.

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

./install.sh   # one-shot: configure (if needed) + install worktrees + alarm
```

`install.sh` self-provisions on first run: if no fish config override exists it
runs `./configure.sh --defaults` (non-interactive, default homes), so
**zero-state setup is a single command**. To customize homes instead, run
`./configure.sh` interactively first — it prompts and is safe to re-run.

Then reload fish (`source ~/.config/fish/conf.d/worktrees.fish` or open a new
shell) and **quit + restart opencode** (the model-routing plugin and
instructions load at startup, not hot-reloaded). Re-running `./install.sh` is
safe; `git pull` in the repo updates the tooling in place (worktrees.fish and
the alarm plugin are symlinked).

## Tests

`./test.sh` runs an automated lifecycle test against throwaway repos in a temp
dir (no real repos touched, cleans up after). It covers: start / idempotent
restart / multi-repo / missing-repo preflight / invalid-idea / bogus-destination
/ go / `git plan` matching / merge dirty-main and wrong-branch refusal /
coordinated merge / stop keeps branch / stop refuses dirty without `--force` /
resume / rm / shared python venv (union + auto-activation) / repo-local `.venv`
auto-activation (incl. the PATH-clobber regression) / JS deps / any-directory
invocation / `--description` registry seeding / registry-layer unit tests /
interactive prompting (idea/repos/description, `--save`, lifecycle idea prompts,
`--help`) / and the environment fast-fail guards. Exits nonzero if any test
fails.

```sh
./test.sh
```

## Commands

All commands work from **any directory** (repos under `$__wt_github_home`, ideas
under `$__wt_worktree_home/<idea>`). Missing arguments are **prompted for when
stdin is interactive**: `<idea>` first, then the repo set (defaulting to the
current repo when you're inside one), then — for `worktree-start` only — the
description. Non-interactive (scripted) contexts never prompt: a missing
`<idea>` is a usage error, and a missing repo set falls back to the current repo
when inside one, otherwise fails with a hint to pass `--repos`/`-g`. Set
`__wt_prompt 0` in `worktrees-config.fish` to disable prompting entirely.

Repo selection is mutually exclusive; `--repos` and `-g` never prompt:

- `--repos=A,B,C` — one-off repo set for this invocation (ephemeral).
- `-g NAME` — a named group from `WORKTREE-GROUPS`.
- `--save NAME` — with `--repos`, persist the set as group `NAME`; interactively
  (without `--repos`) it prompts for the set and then saves it.
  (`--repos` + `-g` together is an error.)
- `-h` / `--help` on any command prints its usage and exits 0.

| Command | Action |
|---|---|
| `worktree-start [--repos=A,B,C \| -g NAME] [--save NAME] [--description=TEXT] [--force] [--help] [<idea>]` | Create/resume the worktree(s), cd in, install JS deps in **every repo of the set** with a `package.json` (npm ci with a lockfile, else npm install; pnpm/yarn/bun chosen per lockfile, npm fallback if the manager is missing), provision the shared Python venv (see below), print paired dirs. Two-phase: validates the whole repo set before creating anything. `--description=TEXT` seeds the idea's `WORKTREES.md` row (new row appended; an existing row's description is updated only with `--force`; identical text is a no-op). |
| `worktree-go <idea>` | cd into this repo's worktree, show status + registry row. The shared venv auto-activates. |
| `worktree-venv [--repos=A,B,C \| -g NAME] [--force] [--help] [<idea>]` | Ensure/refresh the shared venv for a repo set; print its path; activate if already in a participating worktree. Honors a `.python-version` pin (recreates on minor mismatch). |
| `worktree-merge [--repos=A,B,C \| -g NAME] [--help] [<idea>]` | Coordinated rebase-onto-local-`main` then `--ff-only` merge into each main. No push. Not a cross-repo transaction. |
| `worktree-stop [--repos=A,B,C \| -g NAME] [--force] [--help] [<idea>]` | Park: remove the worktree dir, keep the branch. Refuses if dirty unless `--force`. |
| `worktree-rm [--repos=A,B,C \| -g NAME] [--force] [--help] [<idea>]` | Tear down: remove the worktree, then delete the branch (safe-first; confirms before `-D`), then remove the shared venv. |
| `worktree-list` | Global recall: the idea registry plus every worktree across all repos. |
| `git plan` | Show this idea's registry row from the global `$__wt_worktree_home/WORKTREES.md`. |
| `venv-activate <venv>` | Manually activate a Python venv through the same manager the auto-activation uses, so PATH is preserved (see *Repo-local .venv*). |

For `merge`/`stop`/`rm`/`venv`, when neither `--repos` nor `-g` is given, the
repo set is derived from the idea's existing worktree directories (or the
current repo when you're inside one) — so `worktree-merge <idea>` from a neutral
directory merges every repo the idea already has worktrees in.

`<idea>` must satisfy `<idea> == branch == one directory component` (validated;
no `/`, no leading `-`, must be a valid Git ref). `main` always means the
**local** `main` branch — the tool never fetches or pushes.

## Lifecycle

```text
author plan -> register (global WORKTREES.md) -> worktree-start ->
develop/commit -> worktree-merge -> worktree-stop (park) | worktree-rm (teardown)
-> update WORKTREES.md
```

- `worktree-start` is idempotent: existing worktree -> just cd; parked branch ->
  re-attach; missing -> create off `main`.
- The **register** step is automated when you pass `--description=TEXT` to
  `worktree-start`: it seeds (or updates, with `--force`) the idea's row in
  `WORKTREES.md`. Without `--description` the registry is left untouched.
- `worktree-stop` keeps the branch (resume later with `start`); `worktree-rm`
  deletes it (done forever) and removes the idea's shared venv (recreatable on
  the next `start`).
- `worktree-merge` is *coordinated, not transactional*: preflight all repos,
  rebase all branches, then fast-forward all mains. On a phase-1 failure no
  main is merged, but some idea branches may already have been rebased.

## Shared Python venv

Each idea gets **one** venv at `$__wt_venv_home/<idea>` (default
`$__wt_worktree_home/.venvs/<idea>`) that is the **superset of the Python
requirements from every repo in the idea's repo set** — not one venv per
worktree. `worktree-start` provisions it before cd'ing in.

Union resolution, per repo (from its **main clone**):

- `pyproject.toml` present → installed **editable** (`-e <main clone>`), and it
  *wins* over a sibling `requirements.txt`.
- otherwise `requirements.txt` present → installed via `-r <main clone>/requirements.txt`.
- neither → the repo contributes nothing.

Installer: **uv** when on PATH (creates the venv and re-syncs deps on every
`start` — fast, self-heals set changes); else `python3 -m venv` + pip (installs
only on create, or with `worktree-venv --force`). If any repo has a Python
manifest but **neither `uv` nor `python3`** is available, `worktree-start`
**fast-fails before creating anything**.

**Interpreter pinning (`.python-version`):** if any repo in the set carries a
`.python-version` pin (e.g. `3.13`), the shared venv is created on that
interpreter, and an existing venv on a different major.minor is **recreated**
onto the pin. Pin when a dependency lacks prebuilt wheels for the newest local
Python (example: `pydantic-core`/`jaconv` have no macOS **cp314** wheel, so a
3.14 venv compiles `pydantic-core` from Rust on every fresh install — minutes
of CPU). Pinning to `3.13` keeps `uv` on prebuilt wheels so provisioning is
instant. The pin is read from the first repo in the set that has one (repo
order matters).

**Removing the pin later:** the reminder to re-evaluate lives as a comment in
the pinned repo's manifest itself (`pyproject.toml` / `requirements.txt`). When
the ecosystem catches up (a wheel exists for the newer interpreter), delete the
pin and run `worktree-venv --force <idea>` to rebuild the venv on the newer
Python. Removing the pin is safe at any time — the venv keeps its current
interpreter until you force-recreate it.

Shell integration: a `PWD`-change handler auto-activates the venv whenever you
cd into any of the idea's worktrees (or a subdirectory of one) and deactivates
when you leave or switch to another idea's worktree. `worktree-start` and
`worktree-go` get this for free; `worktree-venv` can also ensure/refresh the
venv on demand.

## Repo-local `.venv`

In addition to the shared per-idea venv, any directory that contains a `.venv`
(typically a **main clone** such as `~/github/grantha-data`) is auto-activated
on cd — walk up from the working directory for a `.venv/bin/activate.fish`,
capped at `$HOME` — and deactivated on leaving. Worktree directories are exempt
(the shared idea venv above owns them). This is enabled by default; disable it
with `set -g __wt_auto_repo_venv 0` in `worktrees-config.fish`.

Activation goes through a single manager that is immune to the classic
**venv-in-venv PATH clobber**: a shell spawned from inside an active venv
inherits `activate.fish`'s internal `_OLD_VIRTUAL_PATH`, and a naive
`source .../activate.fish` would then restore a stale PATH missing global tools
(e.g. `~/.bun/bin`). The manager scrubs inherited `_OLD_*` vars at startup,
strips an inherited venv's `bin` from PATH before activating, and is idempotent
per venv. It also disables `activate.fish`'s prompt override
(`VIRTUAL_ENV_DISABLE_PROMPT`) so programmatic activation never rewrites your
`fish_prompt` or collides with a stale `_old_fish_prompt`. To activate by hand,
prefer `venv-activate .venv` over a raw `source .venv/bin/activate.fish` — it
uses the same safe path.

On every actual activation/deactivation the manager prints the venv path to
stderr (`activated venv: <path>` / `deactivated venv: <path>`), so the current
venv is always visible in the terminal history without a prompt indicator.
(Internal cd round-trips, e.g. during `worktree-start`, are quiet.)

## Registry (`WORKTREES.md`)

A single **global** registry at `$__wt_worktree_home/WORKTREES.md` (default
`~/git-worktrees/WORKTREES.md`, alongside `WORKTREE-GROUPS`) — not per-repo.
One row per **idea** (an idea can span several repos), so `git plan` works from
any of its worktrees:

| Idea | Branch | Repos | Description | Plan file | Status |
|---|---|---|---|---|---|
| `bring-in-ramayana-govindaraja` | `bring-in-ramayana-govindaraja` | grantha-data grantha-explorer ramayana | Port Govindaraja's commentary | plans/PLAN_bring-in-ramayana-govindaraja.md | active |

It is **human-maintained, auto-seeded on `worktree-start`**: passing
`--description=TEXT` appends a new row for the idea (creating the file + header
when absent) or — with `--force` — overwrites an existing row's Description.
Without `--description` the registry is never touched. The tooling prints
reminders at lifecycle boundaries and never edits the Status column (that stays
yours, as does anything you hand-edit — the auto-seeder only ever writes the
row's Description). The Status column uses `active | parked | merged |
abandoned`.

**Schema:** the header must include the `Description` column
(`| Idea | Branch | Repos | Description | Plan file | Status |`). Auto-seeding
refuses (with a migration hint) on an old-schema registry that lacks it.

## WORKTREE-GROUPS

```
default: grantha-data grantha-explorer
ramayana: grantha-data grantha-explorer ramayana
```

Group names are `[a-z0-9][a-z0-9-]*` (validated; first char must be
alphanumeric, so no leading dash). Repos are alphabetized on `--save`.

## Known limitations

- **Python editable installs point at `main`** — a pyproject repo's package is
  installed `-e` from its **main clone**, so `import`/console scripts run the
  main checkout's code, not your idea branch's. The venv is per-idea and
  survives `stop`/`rm`, so this keeps it stable; run `worktree-venv --force` if
  you need it rebuilt.
- **Repo-local `.venv` activation is directory-driven, not repo-driven** — it
  keys off the presence of `.venv`, so it fires in any directory (not only git
  repos) and won't distinguish two checkouts that share an ancestor with a
  `.venv`. A raw `source .venv/bin/activate.fish` still carries the PATH clobber
  described above — use `venv-activate .venv` instead.
- **pip fallback doesn't self-heal** — without `uv`, set changes need
  `worktree-venv --force` (uv re-syncs automatically).
- **`main` is local** — keeping it current with `origin` is your job.
- **Cross-repo operations are best-effort sequential** — `stop`/`rm` abort on a
  dirty repo in the middle; each per-repo step is individually safe.
- **Prompting is interactive-only** — a scripted (piped) invocation never
  prompts; it falls back to the current repo or fails with a hint, so pass
  `--repos`/`-g` in scripts.
- **`--force` means different things per command** — on `worktree-start` it
  overwrites an existing registry Description; on `worktree-stop`/`worktree-rm`
  it discards uncommitted changes. Don't assume one flag, one meaning.
- **`git plan`** relies on POSIX `sh` for the `!` alias (backticks escaped); the
  escaping is verified sound, but host `/bin/sh` variance is a residual risk.
  It is a git alias, so it inherently only runs inside a git worktree.

## Future work

Idea-centric `worktree-list` dashboard; non-mutating
stale-`main` warning; interactive skip/stash for mid-set stop/rm. Deliberately
excluded: auto-commit/push/PR, state databases, daemons — Git stays the state
machine.

## opencode model-routing

DeepSeek Pro/Flash routing alarm. Two pieces, both loaded from the **global**
opencode config by reference (nothing is copied into `~/.config/opencode/`):

| Piece | File | Loaded via | Handles |
|---|---|---|---|
| Alarm plugin | `opencode/model-routing-alarm.js` | symlink into `opencode`'s plugin dir (auto-discovered) | mechanical signals (countable thresholds) |
| Routing contract | `opencode/model-routing.md` | `opencode.json` → `instructions` | judgment signals + Pro/Flash working agreement |

`./install.sh` installs both: it symlinks the plugin into
`~/.config/opencode/plugin/` and merges the contract into
`~/.config/opencode/opencode.json` (atomic write, timestamped backup, no-op on
re-run). **Quit and restart opencode after installing** — config is read at
startup, not hot-reloaded.

### How the plugin decides

Per-session state machine over `tool.execute.after`:

| Signal | Trigger | Default threshold | Direction |
|---|---|---|---|
| Failing test runs | bash invokes `pytest`/`bazel test`/`vitest`/`jest`/`npm test`/`go test`/`mix test`/`mvn test` and output shows a failure | 2 consecutive | → Pro |
| Same-file loop | repeated edit/write to the identical `filePath` | 4 consecutive | → Pro |
| Mechanical green phase | passing test runs while the session model is Pro | 5 consecutive | → Flash |

An alarm is a macOS `osascript` notification **plus** a queued session banner
(injected via `client.session.prompt`, `noReply` — visible, does not interrupt
the running agent; the text says acknowledge, don't act). Counters reset on
alarm, on a passing test, or on a file change; a cooldown (default 10 min)
prevents spam. The plugin never throws — any failure degrades to a log line in
`/tmp/model-routing-alarm.log`.

### Configure

Thresholds are env-tunable in the environment that launches opencode:

| Env var | Default | Meaning |
|---|---|---|
| `MODEL_ROUTING_FAIL_THRESHOLD` | `2` | consecutive failing test runs → Pro |
| `MODEL_ROUTING_LOOP_THRESHOLD` | `4` | consecutive edits to one file → Pro |
| `MODEL_ROUTING_GREEN_THRESHOLD` | `5` | consecutive green passes on Pro → Flash |
| `MODEL_ROUTING_COOLDOWN_MIN` | `10` | minutes between alarms |
| `MODEL_ROUTING_NOTIFY` | `1` | set `0` to silence the macOS notification (banner only) |
| `MODEL_ROUTING_DEBUG` | — | `1` for stderr logging |

### Judgment signals (in the contract, not the plugin)

Signals only the model can assess — silent Indic-normalization corruption
(wrong-but-passing), cross-language contract drift (Python ↔ TypeScript ↔
Next.js), Bazel build-graph weirdness, and >20 minutes without a hypothesis.
The contract instructs the agent to emit a loud `⚠️ SWITCH-TO-PRO:` /
`⚠️ SWITCH-TO-FLASH:` marker with a one-line reason when one fires.

### Verify

1. Restart opencode.
2. Run a deliberately failing `pytest` twice → notification + banner fire.
3. Run the same command twice with green output → no alarm.

### Known limitations

- **Plugin runtime behavior is not automated-tested** — `test.sh` covers syntax
  (`node --check`), install, and config-merge idempotency; the live alarm needs
  a running opencode server, so it is verified manually per the steps above.
- **`osascript` may be unavailable** (non-macOS) → the notification is silently
  skipped; the session banner still works.
- **Editing the contract** (`model-routing.md`) does not require a restart;
  editing the plugin or `opencode.json` does.
- **Uninstall/restore**: remove the `model-routing-alarm.js` symlink, drop the
  `instructions` entry from `opencode.json` (or restore the timestamped backup
  `opencode.json.bak-*` left by the merge), then restart opencode.
