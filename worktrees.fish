# worktrees.fish — idea-workspace tooling built on `git worktree`.
#
# The unit of work is an IDEA, not a repository. An idea can span multiple
# repos: one idea -> same branch/idea name -> one worktree per participating
# repo. This file provides the lifecycle commands (start/go/merge/stop/rm/list)
# plus the `git plan` alias (registered separately by install.sh).
#
# Layout:
#   $__wt_github_home/<repo>              main clones   (default: ~/github)
#   $__wt_worktree_home/<idea>/<repo>     worktrees     (default: ~/git-worktrees)
#   $__wt_venv_home/<idea>                shared venv   (default: ~/git-worktrees/.venvs)
#
# Each idea gets ONE shared Python venv that is the union of every participating
# repo's Python manifests (pyproject.toml -> editable install; else
# requirements.txt). It is created on worktree-start, kept by worktree-stop,
# removed by worktree-rm, and auto-activated on cd into any of the idea's
# worktrees.
#
# Repo selection (default varies — see __wt_resolve_repos):
#   --repos=A,B,C   one-off set for this invocation (ephemeral, no prompt)
#
# All commands work from ANY directory: repos are located under
# $__wt_github_home, ideas under $__wt_worktree_home/<idea>. When a required
# argument (idea, repo set, description) is missing and stdin is interactive,
# the command prompts for it. Non-interactive contexts fall back to the
# current repo (when inside one) or fail with a hint to pass --repos/-g.
#
# Lifecycle:
#   author plan -> worktree-start (writes IDEA.md) -> develop/commit ->
#   worktree-merge (rebase+ff, no push) -> worktree-stop (park) |
#   worktree-rm (teardown)
#
# `main` always means the LOCAL main branch; this tool never fetches or pushes.
# Each idea's metadata lives in $__wt_worktree_home/<idea>/IDEA.md (created by
# worktree-start; Status auto-maintained as `active | parked | merged`; the
# rest is free-form and human-editable; removed with the idea dir by
# worktree-rm).
#
# See README.md in this repo for the full guide.

# --- environment guard (fast-fail) ------------------------------------------
# Refuse to load on unsupported fish/git instead of failing cryptically at
# first use. `return` at the top level of a sourced file stops sourcing and
# propagates a nonzero status (verified). Uses only fish >= 3.0 syntax
# (string match/split) so a clean "too old" message is guaranteed down to 3.0.
set -l __wt_fish_ver (fish --version 2>/dev/null | string match -r '[0-9.]+')
set -l __wt_git_ver (git --version 2>/dev/null | string match -r '[0-9.]+')
if test -z "$__wt_fish_ver"
    echo "worktrees.fish: could not determine fish version" >&2
    return 1
end
if test -z "$__wt_git_ver"
    echo "worktrees.fish: could not determine git version" >&2
    return 1
end
# version compare "X.Y[.Z]" — compares major, minor, and (defaulted) patch.
function __wt_version_ge
    set -l cur (string split . $argv[1])
    set -l req (string split . $argv[2])
    while test (count $cur) -lt 3; set -a cur 0; end
    while test (count $req) -lt 3; set -a req 0; end
    set -l c (math $cur[1] \* 1000000 + $cur[2] \* 1000 + $cur[3])
    set -l r (math $req[1] \* 1000000 + $req[2] \* 1000 + $req[3])
    test $c -ge $r
end
if not __wt_version_ge "$__wt_fish_ver" "3.3"
    echo "worktrees.fish: fish $__wt_fish_ver is too old (need >= 3.3; 'path' builtin)" >&2
    echo "upgrade fish (brew upgrade fish) and reopen your shell" >&2
    return 1
end
if not __wt_version_ge "$__wt_git_ver" "2.31"
    echo "worktrees.fish: git $__wt_git_ver is too old (need >= 2.31; '--path-format=absolute')" >&2
    echo "upgrade git (brew upgrade git) and reopen your shell" >&2
    return 1
end
functions -e __wt_version_ge

# --- inherited-venv-state scrub ---------------------------------------------
# `activate.fish` begins with `deactivate nondestructive`, which restores
# `_OLD_VIRTUAL_PATH`. When this shell was spawned from inside an active venv
# (e.g. opencode launched from a project venv), those *_OLD_* vars are inherited
# STALE — the first `source activate.fish` in this shell would then restore a
# PATH that predates the global tools (bun, ~/.local/bin) before prepending
# .venv/bin, silently dropping them. Scrub the inherited copies so any later
# activation snapshots the CURRENT path. `set -q` guard: `set -e` on an unset
# variable errors.
function __wt_scrub_inherited_venv_state
    for v in _OLD_VIRTUAL_PATH _OLD_VIRTUAL_PYTHONHOME _OLD_FISH_PROMPT_OVERRIDE
        set -q $v; and set -e $v
    end
end
__wt_scrub_inherited_venv_state

# --- global-tools re-assertion ---------------------------------------------
# Scrubbing stale inherited *_OLD_* vars stops the *next* activation from
# restoring a poisoned PATH, but a shell spawned inside an active venv may
# already have dropped the global tool dirs from PATH (anything added via
# `fish_add_path`, i.e. `$fish_user_paths`, is vulnerable to an ad-hoc
# `set PATH` clobber by a stale `deactivate`). Re-assert `$fish_user_paths`
# so a poisoned shell heals itself at load and after every venv change; the
# `contains` guard keeps the prepend idempotent (no duplicated PATH entries).
# Prepend all missing dirs in one assignment so `$fish_user_paths` priority
# order (first = highest) is preserved.
function __wt_ensure_global_tools
    set -l missing
    for d in $fish_user_paths
        if not contains -- $d $PATH
            set -a missing $d
        end
    end
    if set -q missing[1]
        set -gx PATH $missing $PATH
    end
end
__wt_ensure_global_tools

# --- configuration ---------------------------------------------------------
# Roots for main clones and worktrees. configure.sh writes these to
# ~/.config/fish/conf.d/worktrees-config.fish, which loads AFTER config.fish —
# so a `set -g` in config.fish is clobbered. Override by editing that conf.d
# file (or `set -U`, which outranks file sourcing).
#
#   $__wt_github_home    where main clones live   (default: ~/github)
#   $__wt_worktree_home  where worktrees live      (default: ~/git-worktrees)
if not set -q __wt_github_home
    set -g __wt_github_home ~/github
end
if not set -q __wt_worktree_home
    set -g __wt_worktree_home ~/git-worktrees
end
if not set -q __wt_venv_home
    set -g __wt_venv_home $__wt_worktree_home/.venvs
end
# __wt_auto_repo_venv — auto-activate a repo-local `.venv` on cd into any
# directory that contains one (direnv-style). Worktree directories are exempt
# (the worktree handler owns their shared idea venv). Set `0` in
# worktrees-config.fish to disable.
if not set -q __wt_auto_repo_venv
    set -g __wt_auto_repo_venv 1
end
# __wt_prompt — when 1 (default), missing arguments (idea, repo set,
# description) are prompted for interactively. Set `0` in worktrees-config.fish
# to disable prompting entirely (non-interactive fallbacks apply everywhere).
if not set -q __wt_prompt
    set -g __wt_prompt 1
end
# __wt_repo_name — basename of the current repo (works in main clone and in
# any linked worktree, since the common dir resolves to the main repo's .git
# in both cases). Exits 1 when not inside a git repository.
# NOTE: `--git-common-dir` resolves to the main repo's .git in a linked
# worktree; `--path-format=absolute` makes it absolute. There is no
# `--absolute-git-common-dir` option — Apple Git 2.39 echoes an unknown option
# as a literal string, which would break basename/dirname.
function __wt_repo_name
    set -l common (git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    test -n "$common"; or return 1
    basename (dirname "$common")
end

# __wt_split_repos — "a, b ,c" -> one trimmed non-empty repo per line.
function __wt_split_repos
    string split , $argv[1] | string trim | string match -rv '^$'
end

# __wt_resolve_repos — turn the parsed flags (or the default) into the repo
# list, one per line. Works from any directory.
#   $argv[1] = --repos CSV value (may be empty)
#   $argv[2] = unused (was the -g group name; groups were removed)
#   $argv[3] = idea name
#   $argv[4] = derive flag: 1 => merge/stop/rm (see below), 0 => start/venv
# Precedence: --repos > derive (merge/stop/rm) > interactive prompt
# (start/venv) > current repo > helpful error.
#
# NOTE on error output: this function is always called from a command
# substitution (`set -l repos (...)`). A nested substitution runs in a fish
# subshell whose stderr goes STRAIGHT TO THE TERMINAL — a plain `echo ... >&2`
# here would escape every caller redirect and be uncapturable. So on failure
# the message is printed to STDOUT (captured) and the caller re-emits it to
# stderr; on success stdout is the repo list and the failure path never runs.
function __wt_resolve_repos
    if test -n "$argv[1]"
        __wt_split_repos $argv[1]
    else if test "$argv[4]" = 1
        # merge/stop/rm: the idea's existing worktree dirs define the set.
        # The current repo is used ONLY when it actually has a worktree for
        # this idea; from a non-participating repo (or a neutral cwd) we fall
        # back to every repo that has one — so e.g. `worktree-rm <idea>` from
        # the tooling repo tears the whole idea down instead of stalling on
        # "no worktree" for the current repo.
        # An idea dir with NO worktree subdirs (fully parked/torn-down, or an
        # orphaned leftover) yields an EMPTY set — so teardown of the idea dir
        # itself can still run. The hard error is reserved for when the idea
        # dir doesn't exist either.
        set -l cur (__wt_repo_name 2>/dev/null)
        if test -n "$cur"; and test -d (__wt_wt_path $argv[3] $cur)
            echo $cur
        else
            set -l derived
            for repo_dir in (__wt_idea_path $argv[3])/*
                test -d $repo_dir; or continue
                set -a derived (basename $repo_dir)
            end
            if set -q derived[1]
                printf '%s\n' $derived
            else if test -d (__wt_idea_path $argv[3])
                return 0   # empty set: orphaned idea dir, teardown path runs
            else
                echo "not inside a git repository and no worktree dirs for idea '$argv[3]' (pass --repos=A,B,C)"
                return 1
            end
        end
    else if __wt_is_interactive
        __wt_repo_prompt (__wt_repo_name 2>/dev/null)
    else
        set -l cur (__wt_repo_name 2>/dev/null)
        if test -n "$cur"
            echo $cur
        else
            echo "not inside a git repository and no --repos given (pass --repos=A,B,C, or run interactively to be prompted)"
            return 1
        end
    end
end

# __wt_validate_idea — enforce the central invariant:
#   <idea> == git branch name == one directory name.
# Rejects empty, path separators (`/`), leading `-` (so the name is never
# mis-parsed as an option by git or string), and anything git itself refuses
# as a ref component (`..`, trailing `.`, control chars, spaces).
# NOTE: `git check-ref-format` alone accepts `-foo`, so the leading-dash check
# is explicit; and `string match` needs `--` or a `-foo` argument is taken as
# an option.
function __wt_validate_idea
    set -l idea $argv[1]
    test -n "$idea"; or return 1
    string match -q -- '*/*' $idea; and return 1   # single path component
    string match -q -- '-*' $idea; and return 1    # no leading dash
    git check-ref-format "refs/heads/$idea" >/dev/null 2>&1
end

# --- interactive prompting --------------------------------------------------
# Commands work from any directory and prompt for missing arguments when stdin
# is interactive (or when the __wt_force_prompt test hook is set). Each prompt
# helper is small and reads exactly one line, so the suite can drive them
# deterministically by piping stdin.

# __wt_is_interactive — 0 (true) when prompting is enabled AND stdin is a tty
# OR the __wt_force_prompt test hook is set. `__wt_prompt` is the master
# kill-switch (set 0 in worktrees-config.fish to disable all prompting).
function __wt_is_interactive
    test "$__wt_prompt" = 0; and return 1
    isatty stdin; or test "$__wt_force_prompt" = 1
end

# __wt_prompt_idea — read an idea name; required, must validate. Skips empty
# lines (stray newlines, accidental Enter) and re-prompts; errors only when
# input is exhausted. Prints the name on success. The read target is the
# pre-declared function-local `answer` (bare `read`, no -l): a `-l` inside
# the loop would shadow it with a loop-block-local that is discarded each
# iteration.
function __wt_prompt_idea
    set -l answer ""
    while test -z "$answer"
        read -P "idea name: " answer
        or begin
            echo "idea name is required" >&2
            return 1
        end
        set answer (string trim $answer)
    end
    __wt_validate_idea $answer; or begin
        echo "invalid idea name '$answer'" >&2
        return 1
    end
    echo $answer
end

# __wt_repo_prompt — read a repo set (comma/space separated). Empty input uses
# $argv[1] as the default; empty input with NO default fails. Normalizes and
# splits like --repos.
function __wt_repo_prompt
    set -l def $argv[1]
    if test -n "$def"
        read -P "repos (default: $def): " answer
    else
        read -P "repos (required; comma-separated): " answer
    end
    set answer (string trim $answer)
    if test -z "$answer"
        test -n "$def"; or begin
            echo "no repos given (pass --repos=A,B,C)" >&2
            return 1
        end
        echo $def
        return 0
    end
    string replace -ra '[ ,]+' ',' $answer | string split , | string trim | string match -rv '^$'
end

# __wt_prompt_description — read a free-text description; empty input = none.
function __wt_prompt_description
    read -P "description (optional): " description
    set description (string trim $description)
    test -n "$description"; and echo $description
end

# --- per-idea IDEA.md metadata ----------------------------------------------
# Each idea's metadata lives at $__wt_worktree_home/<idea>/IDEA.md — co-located
# with the worktrees, so the idea dir's existence IS the registry entry. There
# is no global registry to keep in sync. Fields:
#   # Idea: <idea>
#   Status: active | parked | merged        (auto-maintained by the tooling)
#   Repos: <space-joined repos>
#   Description: <free text>                (human-editable)
#   Plan: <free text>                       (human-editable)
# Status is rewritten by start/stop/merge; the rest are free-form and may be
# hand-edited. worktree-rm removes the file with the idea dir (the history of
# finished ideas lives in git branches, not here).

# __wt_idea_md_path — absolute path of an idea's IDEA.md.
function __wt_idea_md_path
    echo $__wt_worktree_home/$argv[1]/IDEA.md
end

# __wt_idea_read_field — the value of a `Field:` line in an idea's IDEA.md, or
# nothing when the file or field is absent.
#
# Usage:   __wt_idea_read_field <idea> <Field>
# Exit codes: 0 ok; 1 field/file missing.
function __wt_idea_read_field
    set -l file (__wt_idea_md_path $argv[1])
    test -f $file; or return 1
    grep -m1 -E "^$argv[2]:" $file 2>/dev/null | string replace -r "^$argv[2]:[ \t]*" ''
end

# __wt_idea_write_meta — (re)write an idea's IDEA.md atomically. Always ensures
# the file exists with `Status: active`, `Repos`, and the idea header. A
# `--description` is written only when given; a conflicting existing description
# aborts without --force. Without --description an existing Description is left
# untouched, and any existing Plan line is preserved either way.
#
# Usage:   __wt_idea_write_meta [--force] [--description=TEXT] <idea> <repos...>
# Exit codes: 0 ok (written or no-op); 1 conflicting description / write failure.
function __wt_idea_write_meta
    argparse 'f/force' 'description=' -- $argv; or return 1
    set -l idea $argv[1]
    set -l repos $argv[2..-1]
    set -l file (__wt_idea_md_path $idea)
    mkdir -p (dirname $file); or return 1
    set -l description ""
    if set -q _flag_description
        set description $_flag_description
    end
    if test -f $file
        set -l existing (__wt_idea_read_field $idea Description)
        if test -n "$description"; and test -n "$existing"; and not test "$existing" = "$description"
            if not set -q _flag_force
                echo "IDEA.md for '$idea' has a different description (pass --force to overwrite):" >&2
                echo "  existing: $existing" >&2
                echo "  new:      $description" >&2
                return 1
            end
        end
        test -n "$description"; or set description $existing
    end
    set -l plan (__wt_idea_read_field $idea Plan)
    set -l tmp (mktemp (dirname $file)/IDEA.md.XXXXXX); or return 1
    echo "# Idea: $idea" > $tmp
    echo "Status: active" >> $tmp
    echo "Repos: "(string join ' ' $repos) >> $tmp
    echo "Description: $description" >> $tmp
    echo "Plan: $plan" >> $tmp
    mv $tmp $file; or begin
        rm -f $tmp
        return 1
    end
end

# __wt_idea_set_status — rewrite only the `Status:` line of an idea's IDEA.md,
# preserving every other line. Creates the file with the given status if absent
# (defensive: status transitions always follow a start, which writes the file).
#
# Usage:   __wt_idea_set_status <idea> <status>
# Exit codes: 0 ok; 1 write failure.
function __wt_idea_set_status
    set -l idea $argv[1]
    set -l new_status $argv[2]
    set -l file (__wt_idea_md_path $idea)
    if not test -f $file
        mkdir -p (dirname $file); or return 1
        echo "# Idea: $idea" > $file; or return 1
    end
    set -l tmp (mktemp (dirname $file)/IDEA.md.XXXXXX); or return 1
    set -l matched 0
    while read -l line
        if string match -q -- 'Status:*' $line
            echo "Status: $new_status"
            set matched 1
        else
            echo $line
        end
    end < $file > $tmp
    if test $matched -eq 0
        echo "Status: $new_status" >> $tmp
    end
    mv $tmp $file; or begin
        rm -f $tmp
        return 1
    end
end

# --- shared per-idea node deps ----------------------------------------------
# JS node_modules is per-worktree (gitignored, like .next/), so each worktree
# needs its own install. On worktree-start we install deps in EVERY repo of
# the set that has a package.json (not just the one we cd into), choosing the
# manager from the worktree's lockfile. Best-effort: a failing install warns
# but never aborts worktree-start — the worktree stays usable, and the user
# can install manually.

# __wt_js_manager — the JS package manager a worktree's lockfile implies, or
# npm when there is no lockfile. Prints pnpm | yarn | bun | npm.
#
# Usage:   __wt_js_manager <worktree-root>
# Exit codes: 0 always (a manager is always printed).
function __wt_js_manager
    set -l root $argv[1]
    if test -f $root/pnpm-lock.yaml
        echo pnpm
    else if test -f $root/yarn.lock
        echo yarn
    else if test -f $root/bun.lockb; or test -f $root/bun.lock
        echo bun
    else
        echo npm
    end
end

# __wt_npm_install — install with npm, deterministic (npm ci) when a
# package-lock.json is present, else plain `npm install`. Must run from inside
# the target worktree.
#
# Usage:   __wt_npm_install
# Exit codes: the npm command's status.
function __wt_npm_install
    if test -f package-lock.json
        npm ci
    else
        npm install
    end
end

# __wt_ensure_node — install JS deps for one repo's worktree of an idea.
#
# No-op (returns 0) when the worktree has no package.json or already has
# node_modules. Otherwise cds into the worktree and installs with the
# lockfile's manager if it is on PATH, falling back to npm when that manager
# is missing; when npm is also missing the repo is skipped (returns 1).
# Progress and warnings go to stderr.
#
# Usage:   __wt_ensure_node <idea> <repo>
# Exit codes: 0 deps ensured (or nothing to do); 1 no manager on PATH;
#             otherwise the install command's status.
function __wt_ensure_node
    set -l idea $argv[1]
    set -l repo $argv[2]
    set -l root (__wt_wt_path $idea $repo)
    test -f $root/package.json; or return 0
    test -d $root/node_modules; and return 0
    set -l manager (__wt_js_manager $root)
    set -l old_pwd $PWD
    # Suppress venv-activation echoes for these internal cd round-trips (they
    # are not user-initiated venv changes). `-lx` not `-l`: fish locals are
    # invisible to other functions, and the --on-variable PWD handler is a
    # separate function — the flag must be EXPORTED for __wt_activate_venv /
    # __wt_deactivate_venv to see it. (It also lands in the env of the install
    # commands below; harmless.)
    set -lx __wt_quiet_venv 1
    cd $root; or return 1
    set -l install_status 1
    if command -sq $manager
        echo "installing JS deps in $root ($manager)" >&2
        switch $manager
            case npm
                __wt_npm_install
            case pnpm
                pnpm install --frozen-lockfile
            case yarn
                yarn install --immutable
            case bun
                bun install --frozen-lockfile
        end
        set install_status $status
    else if command -sq npm
        echo "warning: $manager not on PATH, falling back to npm for $root" >&2
        __wt_npm_install
        set install_status $status
    else
        echo "warning: no JS package manager on PATH (need '$manager' or npm) —" \
            "skipping $root" >&2
    end
    cd $old_pwd
    return $install_status
end

# --- shared per-idea python venv --------------------------------------------
# Each idea gets ONE venv at $__wt_venv_home/<idea> (default
# $__wt_worktree_home/.venvs/<idea>) that is the UNION of every participating
# repo's Python manifest. It is created on worktree-start, kept by
# worktree-stop, removed by worktree-rm, and auto-activated on cd (see
# __wt_auto_activate_venv). uv is preferred; python3 + pip is the fallback.

# __wt_venv_path — absolute path of the shared venv for an idea.
function __wt_venv_path
    echo $__wt_venv_home/$argv[1]
end

# __wt_wt_path — absolute worktree path for an idea's repo, idea-first:
#   $__wt_worktree_home/<idea>/<repo>
# The single source of truth for the layout, so the component order can never
# drift across call sites. Argument order is ($idea $repo), mirroring the
# directory order.
function __wt_wt_path
    echo $__wt_worktree_home/$argv[1]/$argv[2]
end

# __wt_idea_path — absolute parent directory for an idea's worktrees:
#   $__wt_worktree_home/<idea>
function __wt_idea_path
    echo $__wt_worktree_home/$argv[1]
end

# __wt_idea_live_worktrees — basenames of subdirs under an idea's dir that are
# still valid git worktrees. The teardown safety gate: only when this is empty
# may worktree-rm delete the shared venv and the idea dir itself (a partial
# teardown where another repo's worktree still lives here must NOT touch them).
#
# Usage:   __wt_idea_live_worktrees <idea>
# Exit codes: 0 ok; 1 idea dir missing.
function __wt_idea_live_worktrees
    set -l idea_dir (__wt_idea_path $argv[1])
    test -d $idea_dir; or return 1
    for repo_dir in $idea_dir/*
        test -d $repo_dir; or continue
        if git -C $repo_dir rev-parse --git-dir >/dev/null 2>&1
            basename $repo_dir
        end
    end
end

# __wt_idea_stray_items — top-level entries in an idea's dir that are NOT live
# worktrees: files (dotfiles like .DS_Store included) and leftover subdirs.
# `rm -rf` removes symlinks, not their targets, so deleting these is safe.
#
# Usage:   __wt_idea_stray_items <idea>
# Exit codes: 0 ok; 1 idea dir missing.
function __wt_idea_stray_items
    set -l idea_dir (__wt_idea_path $argv[1])
    test -d $idea_dir; or return 1
    set -l live (__wt_idea_live_worktrees $argv[1])
    for entry in $idea_dir/*
        test -e $entry; or continue
        set -l name (basename $entry)
        contains -- $name $live; and continue
        test "$name" = "IDEA.md"; and continue   # managed metadata, goes with the dir
        echo $name
    end
end

# __wt_python_manifest — the kind of Python manifest a repo's main clone has, or
# nothing. `pyproject.toml` wins over `requirements.txt` (grantha-data has both).
# Prints `pyproject` | `requirements` | (nothing).
function __wt_python_manifest
    set -l main_root $__wt_github_home/$argv[1]
    if test -f $main_root/pyproject.toml
        echo pyproject
    else if test -f $main_root/requirements.txt
        echo requirements
    end
end

# __wt_venv_args — install arguments for the union venv from a repo set.
# pyproject repos contribute `-e <main clone>` (editable; console scripts like
# grantha-converter resolve). requirements-only repos contribute `-r <path>`.
# Prints one argument per line (or nothing if no Python manifests).
function __wt_venv_args
    set -l args
    for repo in $argv
        switch (__wt_python_manifest $repo)
            case pyproject
                set -a args -e $__wt_github_home/$repo
            case requirements
                set -a args -r $__wt_github_home/$repo/requirements.txt
        end
    end
    printf '%s\n' $args
end

# __wt_python_version — the interpreter pin for a repo set, taken from the
# first repo in the set that has a `.python-version` (repo order matters).
# Prints the FIRST non-empty line (e.g. "3.13") or nothing. Keeping the shared
# venv on the same interpreter the repos are developed against lets uv resolve
# prebuilt wheels instead of compiling source wheels from Rust (e.g.
# pydantic-core has no macOS cp314 wheel, so a 3.14 venv compiles it on every
# fresh install).
#
# Usage:   __wt_python_version <repo>...
# Exit codes: 0 always; found-or-not is signalled by empty output.
function __wt_python_version
    for repo in $argv
        set -l f $__wt_github_home/$repo/.python-version
        if test -f $f
            string trim < $f | string match -rv '^$' | head -n1
            return 0
        end
    end
end

# __wt_python_major_minor — "major.minor" version of a python binary, or
# nothing. Requires a readable interpreter at the given path.
#
# Usage:   __wt_python_major_minor <python-path>
# Exit codes: 0 ok; 1 not executable / not readable.
function __wt_python_major_minor
    set -l py $argv[1]
    test -x $py; or return 1
    $py -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null
end

# __wt_version_major_minor — leading "major.minor" of a version string
# ("3.13.11" -> "3.13"). Prints nothing on malformed input.
#
# Usage:   __wt_version_major_minor <version>
# Exit codes: 0 ok; 1 fewer than two dot-separated components.
function __wt_version_major_minor
    set -l parts (string split . $argv[1])
    test (count $parts) -ge 2; or return 1
    echo $parts[1].$parts[2]
end

# __wt_ensure_venv — create/refresh the shared per-idea venv as the union of
# every Python manifest in the repo set. uv-first, python3+pip fallback.
# With uv, re-syncs on every call (fast, self-heals set changes). With pip,
# installs only on create or --force (pip reinstall of grantha-data is slow).
# A `.python-version` pin in any participating repo is honored (uv branch
# only): an existing venv on a different major.minor is recreated so uv can use
# prebuilt wheels. The pip fallback always uses the default `python3`.
# Progress goes to stderr so stdout stays clean for callers.
#
# Usage:   __wt_ensure_venv [--force] <idea> <repos...>
# Exit codes: 0 ok (venv ensured, or no Python manifests / empty repo set);
#             1 any install step failed.
function __wt_ensure_venv
    argparse 'f/force' -- $argv; or return 1
    set -l idea $argv[1]
    set -l repos $argv[2..-1]
    set -l venv (__wt_venv_path $idea)
    test (count $repos) -gt 0; or return 0
    set -l args (__wt_venv_args $repos)
    test -n "$args"; or return 0   # no Python manifests -> no venv to make
    set -l pyver (__wt_python_version $repos)
    if command -sq uv
        set -l rebuild 0
        if not test -d $venv
            set rebuild 1
        else
            set -l cur (__wt_python_major_minor $venv/bin/python)
            set -l want (__wt_version_major_minor $pyver)
            if set -q _flag_force
                echo "recreating venv $venv (uv --force)" >&2
                set rebuild 1
            else if test -z "$cur"; and test -z "$want"
                echo "recreating venv $venv: interpreter missing" >&2
                set rebuild 1
            else if test -z "$cur"
                echo "recreating venv $venv: no usable Python (pinned $pyver)" >&2
                set rebuild 1
            else if test -n "$want"; and test "$cur" != "$want"
                echo "recreating venv $venv: Python $cur does not match pinned $pyver" >&2
                set rebuild 1
            end
        end
        if test $rebuild -eq 1
            test -d $venv; and rm -rf $venv
            echo "creating venv $venv (uv)" >&2
            if test -n "$pyver"
                uv venv --python $pyver $venv; or return 1
            else
                uv venv $venv; or return 1
            end
        end
        echo "installing Python deps for '$idea' (uv)" >&2
        uv pip install --python $venv/bin/python $args; or return 1
    else
        set -l created 0
        if not test -d $venv
            echo "creating venv $venv (python3)" >&2
            python3 -m venv $venv; or return 1
            set created 1
        end
        if test $created -eq 1; or set -q _flag_force
            echo "installing Python deps for '$idea' (pip)" >&2
            $venv/bin/pip install $args; or return 1
        end
    end
end

# __wt_idea_for_pwd — the idea whose worktree the current physical PWD is in,
# or nothing. Works from inside any subdirectory of a worktree. Physical paths
# (path resolve + pwd -P) dodge the macOS /var -> /private/var mismatch that
# this file already handles elsewhere. Never treats the venv home itself as a
# worktree. Layout is idea-first ($wt_home/<idea>/<repo>), so the idea is the
# FIRST path component after the worktree home.
function __wt_idea_for_pwd
    set -l wt_home (path resolve $__wt_worktree_home 2>/dev/null)
    test -n "$wt_home"; or return 0
    set -l here (pwd -P)
    # note: `string match` wildcards cross '/', so this also matches
    # idea/repo/sub/dir — the subdir case is intentional, not a bug to "fix".
    if string match -q -- "$wt_home/*/*" $here
        set -l rel (string replace -- "$wt_home/" '' $here)
        set -l parts (string split / $rel)
        if test (count $parts) -ge 2; and not test "$parts[1]" = (basename $__wt_venv_home)
            echo $parts[1]
        end
    end
end

# __wt_deactivate_venv — deactivate the manager-owned venv, if any. Only acts
# when this session's manager actually activated something ($__wt_active_venv),
# so a venv the user activated by hand (`source .../activate.fish`) is left
# alone. `deactivate` (defined by activate.fish) erases itself when called, so
# the call is guarded by `functions -q` in case a `worktree-rm` of a live venv
# already cleared it. Echoes the deactivated venv path to stderr so a venv
# change is visible in the terminal without polluting callers' stdout.
function __wt_deactivate_venv
    set -q __wt_active_venv; or return 0
    set -l old_venv $__wt_active_venv
    functions -q deactivate; and deactivate
    __wt_ensure_global_tools
    set -e __wt_active_venv
    # stderr: these live in __wt_activate_venv/__wt_deactivate_venv, which are
    # also called from worktree-venv where stdout is DATA (the venv path).
    # Silent during a switch: __wt_activate_venv reports the combined
    # transition in one post-success message instead.
    if not set -q __wt_quiet_venv; and not set -q __wt_switching_venv
        echo "deactivated venv: $old_venv" >&2
    end
end

# __wt_activate_venv — activate a Python venv through a single manager so the
# PATH clobber can never happen. Idempotent per venv (physical path). Before
# sourcing: deactivate whatever is active, scrub inherited *_OLD_* vars, and
# strip an inherited venv's bin from PATH so activate.fish snapshots the TRUE
# baseline (no duplicated .venv/bin entry, and `deactivate` later restores the
# right path). Echoes the resulting venv path to stderr (a switch is reported
# as one `switched venv: A -> B` message, only after it succeeds) so a venv
# change is visible in the terminal without polluting callers' stdout.
#
# Usage:   __wt_activate_venv <venv>
# Exit codes: 0 activated (or already active); 1 venv missing.
function __wt_activate_venv
    set -l venv (path resolve $argv[1] 2>/dev/null)
    test -n "$venv"; or return 1
    if set -q __wt_active_venv; and test "$__wt_active_venv" = "$venv"
        return 0
    end
    # target missing (e.g. no Python manifest) -> deactivate the current venv
    # and stop, so a repo venv never leaks into a context that should have none
    if not test -f "$venv/bin/activate.fish"
        __wt_deactivate_venv
        return 1
    end
    # capture the pre-switch venv (if any) and keep the deactivate silent; the
    # single post-success message below reports the whole transition.
    # `set -l old_venv ""` is pre-declared in FUNCTION scope so the assignment
    # inside the `if` below updates this var, not an if-block-local that would
    # be discarded (misreporting a switch as a fresh activation).
    set -l old_venv ""
    if set -q __wt_active_venv
        set old_venv $__wt_active_venv
    end
    set -l __wt_switching_venv 1
    __wt_deactivate_venv
    if set -q VIRTUAL_ENV
        set -l base (path resolve $VIRTUAL_ENV/bin 2>/dev/null)
        if test -n "$base"
            set -l newpath
            for p in $PATH
                if not test "$p" = "$base"
                    set -a newpath $p
                end
            end
            set -gx PATH $newpath
        end
    end
    __wt_scrub_inherited_venv_state
    __wt_ensure_global_tools
    # Disable activate.fish's prompt override: this manager activates venvs
    # programmatically on every cd, and the prompt override's
    # `functions -c fish_prompt _old_fish_prompt` collides when a stale
    # _old_fish_prompt survives (e.g. a shell spawned from inside a venv). The
    # user's own fish_prompt is left untouched. Scoped to this function so a
    # later manual `source .../activate.fish` still gets the prompt override.
    set -lx VIRTUAL_ENV_DISABLE_PROMPT 1
    if not source $venv/bin/activate.fish
        echo "failed to activate $venv (previous venv deactivated)" >&2
        return 1
    end
    set -g __wt_active_venv $venv
    # single post-success message (reports a switch as one transition)
    if not set -q __wt_quiet_venv
        if test -n "$old_venv"
            echo "switched venv: $old_venv -> $venv" >&2
        else
            echo "activated venv: $venv" >&2
        end
    end
end

# __wt_find_repo_venv — the nearest repo-local `.venv` walking up from PWD,
# capped at $HOME (or filesystem root when $HOME is unreachable), or nothing.
# Physical paths dodge the macOS /var -> /private/var mismatch handled elsewhere
# in this file.
function __wt_find_repo_venv
    set -l here (path resolve $PWD 2>/dev/null)
    test -n "$here"; or return 1
    set -l home (path resolve $HOME 2>/dev/null)
    while true
        if test -f "$here/.venv/bin/activate.fish"
            echo "$here/.venv"
            return 0
        end
        test "$here" = "$home"; and break
        set -l parent (dirname "$here")
        test "$parent" = "$here"; and break
        set here $parent
    end
    return 1
end

# __wt_auto_activate_venv — single PWD-change handler that resolves the venv to
# activate in precedence order: an idea's shared venv (inside a worktree) wins;
# otherwise a repo-local `.venv` (when the toggle is on); otherwise deactivate.
# One handler avoids any reliance on fish's event-handler registration order.
function __wt_auto_activate_venv --on-variable PWD
    set -q __wt_venv_home; or return 0
    set -l idea (__wt_idea_for_pwd)
    if test -n "$idea"
        __wt_activate_venv (__wt_venv_path $idea)
    else if not test "$__wt_auto_repo_venv" = 0
        set -l venv (__wt_find_repo_venv)
        if test -n "$venv"
            __wt_activate_venv $venv
        else
            __wt_deactivate_venv
        end
    else
        __wt_deactivate_venv
    end
end

# --- usage/help -------------------------------------------------------------
# `-h/--help` is handled per-command (argparse has no auto-help) and
# short-circuits BEFORE any prompting, so it works from any directory with
# zero input. All commands work from any directory.

function __wt_usage_start
    echo "worktree-start — create or resume an idea's worktree, then cd in."
    echo "Works from any directory: repos via \$__wt_github_home, ideas via"
    echo "\$__wt_worktree_home/<idea>."
    echo
    echo "Usage:  worktree-start [--repos=A,B,C]"
    echo "                       [--description=TEXT] [--force] [--help] [<idea>]"
    echo
    echo "Arguments:"
    echo "  <idea>          Required (or prompted): == branch == one directory"
    echo "                  component; worktree at \$__wt_worktree_home/<idea>/<repo>."
    echo
    echo "Options:"
    echo "  --repos=A,B,C   Explicit repo set (ephemeral, no prompt)."
    echo "  --description=T Set the idea's IDEA.md Description to T (written"
    echo "                  on start; an existing different description is"
    echo "                  overwritten only with --force; identical is a no-op)."
    echo "  --force         Overwrite an existing IDEA.md description."
    echo "  -h, --help      Show this help."
    echo
    echo "Missing args are prompted for when stdin is interactive (idea, repo"
    echo "set — default: current repo, description). Non-interactive: current"
    echo "repo when inside one, else an error hinting --repos."
    echo
    echo "Exit codes: 0 ok; 1 usage error, invalid idea, prompt declined,"
    echo "preflight failure (nothing created), or venv-provisioning failure."
end

function __wt_usage_merge
    echo "worktree-merge — coordinated rebase-onto-main then --ff-only merge."
    echo "Works from any directory; repos via \$__wt_github_home."
    echo
    echo "Usage:  worktree-merge [--repos=A,B,C] [--help] [<idea>]"
    echo
    echo "  <idea>      Required (or prompted). --repos overrides the repo"
    echo "              set; otherwise inside a repo the current repo is used,"
    echo "              from a neutral dir the idea's existing worktrees are."
    echo "  -h, --help  Show this help."
    echo
    echo "Does NOT push. Exit codes: 0 ok; 1 usage/phase failure."
end

function __wt_usage_stop
    echo "worktree-stop — park a worktree: remove the dir, keep the branch."
    echo "Works from any directory; repos via \$__wt_github_home."
    echo
    echo "Usage:  worktree-stop [--repos=A,B,C] [--force] [--help] [<idea>]"
    echo
    echo "  <idea>      Required (or prompted). --repos overrides the repo"
    echo "              set; otherwise inside a repo the current repo is used,"
    echo "              from a neutral dir the idea's existing worktrees are."
    echo "  --force     Discard uncommitted changes and remove anyway."
    echo "  -h, --help  Show this help."
    echo
    echo "Exit codes: 0 ok; 1 usage error, dirty worktree (no --force), etc."
end

function __wt_usage_rm
    echo "worktree-rm — tear down a worktree and delete its branch (and, on"
    echo "full teardown, the idea's shared venv and idea dir). Works from any"
    echo "directory."
    echo
    echo "Usage:  worktree-rm [--repos=A,B,C] [--force] [--help] [<idea>]"
    echo
    echo "  <idea>      Required (or prompted). --repos overrides the repo"
    echo "              set; otherwise inside a repo the current repo is used,"
    echo "              from a neutral dir the idea's existing worktrees are."
    echo "  --force     Discard uncommitted changes; skip some confirms."
    echo "  -h, --help  Show this help."
    echo
    echo "Full teardown (no worktree remains) removes the shared venv and the"
    echo "idea dir; leftover cruft is confirmed first (default keep). A partial"
    echo "teardown leaves both untouched."
    echo
    echo "Exit codes: 0 ok; 1 usage error, dirty worktree (no --force), etc."
end

function __wt_usage_venv
    echo "worktree-venv — ensure/refresh the shared per-idea Python venv."
    echo "Works from any directory; repos via \$__wt_github_home."
    echo
    echo "Usage:  worktree-venv [--repos=A,B,C] [--force] [--help] [<idea>]"
    echo
    echo "  <idea>      Required (or prompted). --repos overrides the repo"
    echo "              set; otherwise inside a repo the current repo is used,"
    echo "              from a neutral dir the idea's existing worktrees are."
    echo "  --force     Reinstall deps (pip) / recreate the venv (uv)."
    echo "  -h, --help  Show this help."
    echo
    echo "Prints the venv path. Exit codes: 0 ok; 1 usage/invalid, or no"
    echo "Python manifests in the set."
end

# venv-activate — manually activate a Python venv through the same manager used
# by auto-activation, so PATH is preserved (no _OLD_VIRTUAL_PATH clobber) and
# switching venvs deactivates the previous one.
#
# Usage:   venv-activate <venv>
# Exit codes: 0 activated (or already active); 1 usage error or venv not found.
function venv-activate
    if not set -q argv[1]
        echo "usage: venv-activate <venv>" >&2
        return 1
    end
    __wt_activate_venv $argv[1]
end
# worktree-start — create or resume a worktree for an idea, then cd into it.
# Works from ANY directory: repos are located under $__wt_github_home, ideas
# under $__wt_worktree_home/<idea>. Missing arguments (idea, repo set,
# description) are prompted for when stdin is interactive.
#
# Idempotent: if the worktree dir already exists (and is a valid worktree for
# this idea/repo) it just cds in; if the branch exists but the worktree is gone
# it re-attaches; otherwise it creates a fresh branch off `main`. With --repos
# it ensures every repo in the set, cds into the current repo's worktree (or
# the first in the set), and prints all the paired dirs.
#
# --description=T sets the idea's IDEA.md Description (written on start; an
# existing different description is overwritten only with --force; identical
# text is a no-op). A conflicting description is PREFLIGHTED in phase 0 so it
# aborts before anything is created.
#
# Two-phase (mirrors worktree-merge): phase 0 validates the whole repo set
# (main clone exists, is a git repo, has local `main`, destination is either
# absent or a valid worktree for this idea/repo, an interpreter present — uv or
# python3 — if any repo has a Python manifest) BEFORE creating anything, so a
# missing repo cannot leave a partially-created idea. Phase 1 creates/attaches
# worktrees, provisions the shared per-idea venv ($__wt_venv_home/<idea>) as
# the union of every participating repo's Python manifests, and writes the
# idea's IDEA.md (Status active). cd'ing into a worktree then auto-activates
# that venv (see __wt_auto_activate_venv).
#
# <idea> must satisfy <idea> == branch == one directory component (validated by
# __wt_validate_idea). `main` here means the LOCAL main branch — keeping it
# current (fetching origin) is the user's responsibility; this tool never
# fetches or pushes.
#
# Usage:   worktree-start [--repos=A,B,C]
#                         [--description=TEXT] [--force] [--help] [<idea>]
# Flags:   --repos=A,B,C  explicit repo set for this invocation (ephemeral)
#          --description= set the idea's IDEA.md Description to this text
#          --force        overwrite an existing IDEA.md description
#          -h/--help      show usage (works with zero input, any directory)
# Example: worktree-start --repos=grantha-explorer,grantha-data,ramayana \
#                          incorporate-ramayana-govindaraja
#
# Side effects: may install JS deps in every repo of the set that has a
# package.json (best-effort; manager chosen by lockfile, skipped when
# node_modules already present); may create/populate the shared idea venv;
# writes the idea's IDEA.md.
# Exit codes: 0 ok; 1 usage error, invalid idea, any phase-0 validation
# failure (nothing created in that case), or a venv-provisioning failure.
function worktree-start
    argparse 'repos=' 'description=' 'f/force' 'h/help' -- $argv; or return 1
    if set -q _flag_help
        __wt_usage_start
        return 0
    end
    set -l idea ""
    if set -q argv[1]
        set idea $argv[1]
    else if __wt_is_interactive
        set idea (__wt_prompt_idea); or return 1
    else
        echo "usage: worktree-start [--repos=A,B,C] [--description=TEXT] [--force] <idea>" >&2
        return 1
    end
    __wt_validate_idea $idea
    or begin
        echo "worktree-start: invalid idea name '$idea' (must be a single path component and a valid git branch name)" >&2
        return 1
    end
    set -l description ""
    set -l self (__wt_repo_name 2>/dev/null)
    set -l repos (__wt_resolve_repos "$_flag_repos" "" $idea 0)
    or begin
        printf '%s\n' $repos >&2   # resolve prints its error on stdout (captured)
        return 1
    end
    if set -q _flag_description
        set description $_flag_description
    end
    if test -z "$description"; and __wt_is_interactive
        set description (__wt_prompt_description)
    end
    # phase 0 — validate the whole set before mutating anything
    for repo in $repos
        set -l main_root $__wt_github_home/$repo
        set -l path (__wt_wt_path $idea $repo)
        test -d $main_root
        or begin
            echo "worktree-start: no main clone at $main_root" >&2
            return 1
        end
        git -C $main_root rev-parse --git-dir >/dev/null 2>&1
        or begin
            echo "worktree-start: $main_root is not a git repository" >&2
            return 1
        end
        git -C $main_root show-ref --verify --quiet refs/heads/main
        or begin
            echo "worktree-start: $repo has no local 'main' branch" >&2
            return 1
        end
        if test -e $path
            # destination occupied: accept only a valid worktree for THIS idea/repo
            git -C $path rev-parse --git-dir >/dev/null 2>&1
            or begin
                echo "worktree-start: $path exists but is not a git worktree" >&2
                return 1
            end
            set -l wt_common (git -C $path rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
            # compare the REPO NAME (basename of common-dir parent), not the raw
            # path — macOS resolves /var -> /private/var, which would otherwise
            # fail a string comparison on the same repo.
            if not test (basename (dirname "$wt_common")) = $repo
                echo "worktree-start: $path belongs to a different repository" >&2
                return 1
            end
            test (git -C $path branch --show-current) = $idea
            or begin
                echo "worktree-start: $path exists but is not on branch '$idea'" >&2
                return 1
            end
        end
    end
    # phase 0b — python fast-fail: a Python manifest without any interpreter
    # aborts before anything is created. uv manages its own Pythons, so it is
    # only python3 we need when uv is absent.
    for repo in $repos
        set -l manifest (__wt_python_manifest $repo)
        if test -n "$manifest"; and not command -sq uv; and not command -sq python3
            echo "worktree-start: $repo has a Python manifest but neither uv nor python3 is on PATH" >&2
            return 1
        end
    end
    # phase 0c — IDEA.md preflight: a description conflict aborts before
    # anything is created (the same check write_meta re-runs in phase 1).
    if test -n "$description"; and not set -q _flag_force
        set -l existing (__wt_idea_read_field $idea Description)
        if test -n "$existing"; and not test "$existing" = "$description"
            echo "IDEA.md for '$idea' has a different description (pass --force to overwrite):" >&2
            echo "  existing: $existing" >&2
            echo "  new:      $description" >&2
            return 1
        end
    end
    # phase 1 — create/attach (all validated above)
    mkdir -p (__wt_idea_path $idea)   # idea-first parent dir (explicit, not implicit)
    for repo in $repos
        set -l path (__wt_wt_path $idea $repo)
        test -e $path; and continue   # already a valid worktree for this idea
        if git -C $__wt_github_home/$repo show-ref --verify --quiet refs/heads/$idea
            git -C $__wt_github_home/$repo worktree add $path $idea
        else
            git -C $__wt_github_home/$repo worktree add -b $idea $path main
        end
    end
    # shared venv — union of Python manifests across the whole repo set
    __wt_ensure_venv $idea $repos; or return 1
    if test -d (__wt_venv_path $idea)
        echo "venv: "(__wt_venv_path $idea)
    end
    # JS deps — best-effort install in every repo of the set with a package.json
    for repo in $repos
        if not __wt_ensure_node $idea $repo
            echo "warning: could not install JS deps in "(__wt_wt_path $idea $repo)" (install manually)" >&2
        end
    end
    if test (count $repos) -gt 1
        echo "paired worktrees:"
        for repo in $repos
            echo "  "(__wt_wt_path $idea $repo)
        end
    end
    # IDEA.md metadata — always ensured (Status active + Repos), with the
    # description when given (--force to overwrite a conflicting one).
    if test -n "$description"
        if set -q _flag_force
            __wt_idea_write_meta --force --description=$description $idea $repos; or return 1
        else
            __wt_idea_write_meta --description=$description $idea $repos; or return 1
        end
    else
        __wt_idea_write_meta $idea $repos; or return 1
    end
    set -l target $self
    if not contains -- $self $repos
        set target $repos[1]
    end
    cd (__wt_wt_path $idea $target)
    git status -sb
    git plan
end
# worktree-go — cd into a worktree for an idea and refresh context. Works from
# ANY directory, not just a participating repo: from inside a repo that has a
# worktree for the idea it goes to that one; otherwise it falls back to the
# first repo in the idea's set that does. The shared venv auto-activates on cd.
#
# Usage:   worktree-go <idea>
# Example: worktree-go whitespace-normalization
# Exit codes: 0 ok; 1 usage error, invalid idea, or no worktree for the idea.
function worktree-go
    if not set -q argv[1]
        echo "usage: worktree-go <idea>" >&2
        return 1
    end
    set -l idea $argv[1]
    __wt_validate_idea $idea
    or begin
        echo "worktree-go: invalid idea name '$idea'" >&2
        return 1
    end
    set -l target (__wt_repo_name 2>/dev/null)
    if test -z "$target"; or not test -d (__wt_wt_path $idea $target)
        # neutral cwd (e.g. a fresh terminal at ~) or a repo with no worktree
        # for this idea -> use the first repo that has one
        set target ""
        for repo_dir in (__wt_idea_path $idea)/*
            test -d $repo_dir; or continue
            set target (basename $repo_dir)
            break
        end
    end
    test -n "$target"
    or begin
        echo "worktree-go: no worktree for idea '$idea' (run worktree-start first)" >&2
        return 1
    end
    set -l path (__wt_wt_path $idea $target)
    cd $path
    git status -sb
    git plan
end
# worktree-merge — integrate a finished idea into main via rebase + fast-forward.
# Works from any directory; missing <idea> is prompted for when interactive.
#
# Three phases, coordinated across the repo set (NOT a cross-repo transaction —
# per-repo atomicity only; see Known limitations):
#   phase 0  preflight every repo (worktree exists; main clone clean & on
#            'main'; worktree clean) — abort before touching anything
#   phase 1  rebase each branch onto main (abort before any merge on failure)
#   phase 2  --ff-only merge each into its own main
# Does NOT push. Leaves each branch checked out in its worktree.
#
# Usage:   worktree-merge [--repos=A,B,C] [--help] [<idea>]
# Example: worktree-merge --repos=grantha-data,grantha-explorer \
#                          incorporate-ramayana-govindaraja
# Exit codes: 0 ok; 1 usage error or any phase failure. On a phase-1 failure no
# main branch has been merged, but some idea branches may already have been
# rebased (no rollback — see Known limitations). A phase-2 failure is unexpected
# but still possible (hooks, locks, concurrent state changes); it is not
# "impossible", just unusual.
function worktree-merge
    argparse 'repos=' 'h/help' -- $argv; or return 1
    if set -q _flag_help
        __wt_usage_merge
        return 0
    end
    set -l idea ""
    if set -q argv[1]
        set idea $argv[1]
    else if __wt_is_interactive
        set idea (__wt_prompt_idea); or return 1
    else
        echo "usage: worktree-merge [--repos=A,B,C] <idea>" >&2
        return 1
    end
    __wt_validate_idea $idea
    or begin
        echo "worktree-merge: invalid idea name '$idea'" >&2
        return 1
    end
    set -l repos (__wt_resolve_repos "$_flag_repos" "" $idea 1)
    or begin
        printf '%s\n' $repos >&2   # resolve prints its error on stdout (captured)
        return 1
    end
    # phase 0 — preflight everything before touching any main
    for repo in $repos
        set -l main_root $__wt_github_home/$repo
        set -l path (__wt_wt_path $idea $repo)
        test -d $path
        or begin
            echo "worktree-merge: no worktree at $path" >&2
            return 1
        end
        set -l main_dirty (git -C $main_root status --porcelain --untracked-files=no)
        if test -n "$main_dirty"
            echo "worktree-merge: $repo main has uncommitted tracked changes" >&2
            return 1
        end
        set -l current_branch (git -C $main_root branch --show-current)
        if not test "$current_branch" = main
            echo "worktree-merge: $repo main clone is not on 'main' (is '$current_branch')" >&2
            return 1
        end
        set -l worktree_dirty (git -C $path status --porcelain)
        if test -n "$worktree_dirty"
            echo "worktree-merge: $repo worktree has uncommitted changes" >&2
            return 1
        end
    end
    # phase 1 — rebase all (no main mutated yet)
    for repo in $repos
        set -l path (__wt_wt_path $idea $repo)
        git -C $path rebase main
        or begin
            echo "worktree-merge: rebase failed in $repo (conflict?) — no main branch was merged; some idea branches may already be rebased" >&2
            return 1
        end
    end
    # phase 2 — fast-forward merge all
    for repo in $repos
        set -l main_root $__wt_github_home/$repo
        git -C $main_root merge --ff-only $idea
        or begin
            echo "worktree-merge: merge failed in $repo — inspect state" >&2
            return 1
        end
        echo "merged $idea into $repo main"
    end
    __wt_idea_set_status $idea merged; or return 1
    echo "remember to push origin/main in each repo"
end
# worktree-stop — park a worktree: remove the dir but keep the branch.
#
# Refuses when the worktree has uncommitted changes unless --force (which
# discards them). Cds to each repo's main root before removing so the shell
# never dangles inside a removed dir. Works from any directory; missing <idea>
# is prompted for when interactive.
#
# Usage:   worktree-stop [--repos=A,B,C] [--force] [--help] [<idea>]
# Flags:   --force  discard uncommitted changes and remove anyway
#          --help   show usage
# Exit codes: 0 ok; 1 usage error, dirty worktree (no --force), or invalid idea.
function worktree-stop
    argparse 'repos=' 'f/force' 'h/help' -- $argv; or return 1
    if set -q _flag_help
        __wt_usage_stop
        return 0
    end
    set -l idea ""
    if set -q argv[1]
        set idea $argv[1]
    else if __wt_is_interactive
        set idea (__wt_prompt_idea); or return 1
    else
        echo "usage: worktree-stop [--repos=A,B,C] [--force] <idea>" >&2
        return 1
    end
    __wt_validate_idea $idea
    or begin
        echo "worktree-stop: invalid idea name '$idea'" >&2
        return 1
    end
    set -l repos (__wt_resolve_repos "$_flag_repos" "" $idea 1); or return 1
    for repo in $repos
        set -l path (__wt_wt_path $idea $repo)
        test -d $path
        or begin
            echo "worktree-stop: no worktree at $path" >&2
            continue
        end
        set -l dirty (git -C $path status --porcelain)
        if test -n "$dirty"; and not set -q _flag_force
            echo "worktree-stop: $repo worktree has uncommitted changes (--force to discard):" >&2
            printf '%s\n' $dirty >&2
            return 1
        end
        cd $__wt_github_home/$repo
        if test -n "$dirty"
            git worktree remove --force $path
        else
            git worktree remove $path
        end
        echo "parked $path (branch kept)"
    end
    # Status: parked only on FULL park (no live worktree remains); a partial
    # park leaves the idea active.
    set -l live (__wt_idea_live_worktrees $idea)
    if not set -q live[1]
        __wt_idea_set_status $idea parked; or return 1
    end
    rmdir (__wt_idea_path $idea) 2>/dev/null   # drop empty idea dir (mid-set safe)
    echo "update $__wt_worktree_home/IDEA.md Status if parked"
end
# worktree-rm — tear down a worktree and delete its branch.
#
# Removes the worktree first (git refuses branch deletion while a worktree is
# live; a failed removal aborts BEFORE the branch is touched), then deletes the
# branch safe-first: `git branch -d`; if the branch is not merged into main,
# prompts for a second confirmation before `git branch -D`. On FULL teardown
# (no live worktree remains under the idea dir) removes the shared venv
# (prompts) and the idea dir itself — leftover cruft (empty subdirs, .DS_Store,
# stray notes) is listed and confirmed before deletion (default keep). A
# partial teardown (another repo's worktree still lives in the idea dir) leaves
# the venv and the idea dir untouched. Refuses when dirty unless --force. Works
# from any directory; missing <idea> is prompted for when interactive.
#
# Usage:   worktree-rm [--repos=A,B,C] [--force] [--help] [<idea>]
# Flags:   --force  discard uncommitted changes and remove anyway
#          --help   show usage
# Exit codes: 0 ok; 1 usage error, dirty worktree (no --force), failed worktree
# removal, or invalid idea.
function worktree-rm
    argparse 'repos=' 'f/force' 'h/help' -- $argv; or return 1
    if set -q _flag_help
        __wt_usage_rm
        return 0
    end
    set -l idea ""
    if set -q argv[1]
        set idea $argv[1]
    else if __wt_is_interactive
        set idea (__wt_prompt_idea); or return 1
    else
        echo "usage: worktree-rm [--repos=A,B,C] [--force] <idea>" >&2
        return 1
    end
    __wt_validate_idea $idea
    or begin
        echo "worktree-rm: invalid idea name '$idea'" >&2
        return 1
    end
    set -l repos (__wt_resolve_repos "$_flag_repos" "" $idea 1)
    or begin
        printf '%s\n' $repos >&2   # resolve prints its error on stdout (captured)
        return 1
    end
    for repo in $repos
        set -l path (__wt_wt_path $idea $repo)
        test -d $path
        or begin
            echo "worktree-rm: no worktree at $path" >&2
            continue
        end
        set -l dirty (git -C $path status --porcelain)
        if test -n "$dirty"; and not set -q _flag_force
            echo "worktree-rm: $repo worktree has uncommitted changes (--force to discard):" >&2
            printf '%s\n' $dirty >&2
            return 1
        end
        cd $__wt_github_home/$repo
        if test -n "$dirty"
            git worktree remove --force $path
        else
            git worktree remove $path
        end
        or begin
            echo "worktree-rm: failed to remove worktree at $path — inspect state; nothing deleted" >&2
            return 1
        end
        # safe-first branch deletion
        if git branch -d $idea >/dev/null 2>&1
            echo "deleted branch $repo/$idea"
        else
            read -l confirm -P "$repo: branch $idea not merged into main — force delete? [y/N] "
            if string match -q -i 'y*' $confirm
                git branch -D $idea
                echo "force-deleted branch $repo/$idea"
            else
                echo "kept branch $repo/$idea (worktree removed)"
            end
        end
    end
    # teardown is gated on FULL teardown: only when NO live worktree remains
    # under the idea dir may we delete the shared venv and the idea dir itself.
    # A partial teardown (another repo's worktree still lives here) must leave
    # both alone — that repo's venv is shared and its files are in the dir.
    set -l live (__wt_idea_live_worktrees $idea)
    if set -q live[1]
        echo "kept "(__wt_idea_path $idea)" — live worktrees remain: "(string join ' ' $live) >&2
        return 0
    end
    # shared venv (recreatable on next start)
    set -l venv (__wt_venv_path $idea)
    if test -d $venv
        read -l confirm -P "remove shared venv $venv? [Y/n] "
        if string match -q -i 'n*' $confirm
            echo "kept venv $venv"
        else
            rm -rf $venv
            echo "removed venv $venv"
        end
    end
    # idea dir + leftover cruft (empty leftover subdirs, .DS_Store, stray notes)
    set -l idea_dir (__wt_idea_path $idea)
    if test -d $idea_dir
        # belt-and-braces scope guard: the validated idea is a single path
        # component, but never rm -rf outside the worktree home.
        if not string match -q -- "$__wt_worktree_home/*" $idea_dir
            echo "worktree-rm: refusing to delete $idea_dir (outside worktree home)" >&2
            return 1
        end
        set -l stray (__wt_idea_stray_items $idea)
        if set -q stray[1]
            echo "leftover items in $idea_dir (would be deleted):" >&2
            for s in $stray
                echo "  $s" >&2
            end
            read -l confirm -P "remove idea dir $idea_dir and "(count $stray)" leftover item(s)? [y/N] "
            if string match -q -i 'y*' $confirm
                rm -rf $idea_dir
                echo "removed idea dir $idea_dir"
            else
                echo "kept $idea_dir (leftover items left in place)" >&2
            end
        else
            rm -rf $idea_dir   # only empty leftover subdirs remain — silent
            echo "removed idea dir $idea_dir"
        end
    end
    echo "removed idea $idea (worktree, branch, venv, IDEA.md)"
end
# worktree-list — global recall: print every idea's IDEA.md (metadata) plus
# the worktrees under $__wt_worktree_home/<idea>/<repo>. No repo needed.
#
# Usage:   worktree-list
# Exit codes: 0 always (best-effort).
function worktree-list
    set -l venv_home (basename $__wt_venv_home)
    if test -d $__wt_worktree_home
        for idea_dir in $__wt_worktree_home/*
            test -d $idea_dir; or continue
            set -l idea (basename $idea_dir)
            if test "$idea" = "$venv_home"
                continue   # shared venv dir is not an idea
            end
            echo "== $idea =="
            if test -f $idea_dir/IDEA.md
                cat $idea_dir/IDEA.md
            else
                echo "(no IDEA.md)"
            end
            echo
            for repo_dir in $idea_dir/*
                test -d $repo_dir; or continue
                set -l repo (basename $repo_dir)
                git -C $__wt_github_home/$repo worktree list 2>/dev/null \
                    | string match -e "/$idea/"
            end
            echo
        end
    end
end
# worktree-venv — ensure/refresh the shared per-idea venv for a repo set.
# Works from any directory; missing <idea> is prompted for when interactive.
#
# The venv is the UNION of every Python manifest in the set (pyproject -> -e,
# else requirements.txt). uv-first, python3+pip fallback; uv re-syncs each call,
# pip installs on create or --force. Prints the venv path. If the current PWD
# is inside one of the idea's worktrees, activates the venv for this shell.
#
# Usage:   worktree-venv [--repos=A,B,C] [--force] [--help] [<idea>]
# Flags:   --repos=A,B,C  explicit repo set for this invocation (ephemeral)
#          --force        reinstall deps (pip) / recreate the venv (uv, e.g. to
#                         re-pick the interpreter after removing a pin)
#          --help         show usage
# Exit codes: 0 ok; 1 usage error, invalid idea, or no Python
# manifests in the set.
function worktree-venv
    argparse 'repos=' 'f/force' 'h/help' -- $argv; or return 1
    if set -q _flag_help
        __wt_usage_venv
        return 0
    end
    set -l idea ""
    if set -q argv[1]
        set idea $argv[1]
    else if __wt_is_interactive
        set idea (__wt_prompt_idea); or return 1
    else
        echo "usage: worktree-venv [--repos=A,B,C] [--force] <idea>" >&2
        return 1
    end
    __wt_validate_idea $idea
    or begin
        echo "worktree-venv: invalid idea name '$idea'" >&2
        return 1
    end
    set -l repos (__wt_resolve_repos "$_flag_repos" "" $idea 0)
    or begin
        printf '%s\n' $repos >&2   # resolve prints its error on stdout (captured)
        return 1
    end
    if set -q _flag_force
        __wt_ensure_venv --force $idea $repos; or return 1
    else
        __wt_ensure_venv $idea $repos; or return 1
    end
    set -l venv (__wt_venv_path $idea)
    test -d $venv
    or begin
        echo "worktree-venv: no Python manifests in the set — nothing to install" >&2
        return 1
    end
    echo $venv
    set -l here_idea (__wt_idea_for_pwd)
    if test -n "$here_idea"; and test "$here_idea" = "$idea"
        __wt_activate_venv $venv
    end
end
# --- completions ------------------------------------------------------------
# __fish_print_worktrees — every idea that has a worktree, for completion of
# start/go/stop/rm/merge/venv. Idea-first layout: $__wt_worktree_home/<idea>.
# Lists ALL ideas regardless of cwd so a fresh terminal (not inside a repo)
# still completes. Nothing when the worktree home is missing or empty.
function __fish_print_worktrees
    set -l venv_home (basename $__wt_venv_home)
    test -d $__wt_worktree_home; or return 1
    for dir in $__wt_worktree_home/*
        test -d $dir; or continue
        set -l name (basename $dir)
        if not test "$name" = "$venv_home"
            echo $name
        end
    end
end

complete -c worktree-start -f -a '(__fish_print_worktrees)'
complete -c worktree-start -l repos -r -d 'explicit repo set A,B,C'
complete -c worktree-go -f -a '(__fish_print_worktrees)'
complete -c worktree-merge -f -a '(__fish_print_worktrees)'
complete -c worktree-merge -l repos -r -d 'explicit repo set A,B,C'
complete -c worktree-stop -f -a '(__fish_print_worktrees)'
complete -c worktree-stop -l repos -r -d 'explicit repo set A,B,C'
complete -c worktree-stop -s f -l force -d 'discard uncommitted changes'
complete -c worktree-rm -f -a '(__fish_print_worktrees)'
complete -c worktree-rm -l repos -r -d 'explicit repo set A,B,C'
complete -c worktree-rm -s f -l force -d 'discard uncommitted changes'
complete -c worktree-venv -f -a '(__fish_print_worktrees)'
complete -c worktree-venv -l repos -r -d 'explicit repo set A,B,C'
complete -c worktree-venv -s f -l force -d 'reinstall deps / rebuild venv'
complete -c worktree-list -f
complete -c venv-activate -r -d 'Python venv to activate'
