# worktrees.fish — idea-workspace tooling built on `git worktree`.
#
# The unit of work is an IDEA, not a repository. An idea can span multiple
# repos: one idea -> same branch/idea name -> one worktree per participating
# repo. This file provides the lifecycle commands (start/go/merge/stop/rm/list)
# plus the `git plan` alias (registered separately by install.sh).
#
# Layout:
#   $__wt_github_home/<repo>              main clones   (default: ~/github)
#   $__wt_worktree_home/<repo>/<idea>     worktrees     (default: ~/git-worktrees)
#   $__wt_venv_home/<idea>                shared venv   (default: ~/git-worktrees/.venvs)
#
# Each idea gets ONE shared Python venv that is the union of every participating
# repo's Python manifests (pyproject.toml -> editable install; else
# requirements.txt). It is created on worktree-start, kept by worktree-stop,
# removed by worktree-rm, and auto-activated on cd into any of the idea's
# worktrees.
#
# Repo groups (default fan-out sets) live in
#   $__wt_worktree_home/WORKTREE-GROUPS   format: `name: repo1 repo2`
#
# Repo selection (mutually exclusive; default = current repo only):
#   --repos=A,B,C   one-off set for this invocation (ephemeral)
#   -g NAME         a named group from WORKTREE-GROUPS
#   --save NAME     with --repos, persist the set as group NAME
#
# Lifecycle:
#   author plan -> register (WORKTREES.md) -> worktree-start ->
#   develop/commit -> worktree-merge (rebase+ff, no push) ->
#   worktree-stop (park) | worktree-rm (teardown) -> update WORKTREES.md
#
# `main` always means the LOCAL main branch; this tool never fetches or pushes.
# WORKTREES.md is human-maintained metadata (never auto-edited); its Status
# column uses `active | parked | merged | abandoned`.
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

# __wt_validate_group — group names are [a-z0-9][a-z0-9-]* (regex-safe, so the
# `^name:` grep in read/save can never be confused by metacharacters). `--`
# guards against a `-foo` name being parsed as an option.
function __wt_validate_group
    string match -q -r -- '^[a-z0-9][a-z0-9-]*$' $argv[1]
end

# __wt_read_group — print the repo list for a named group from WORKTREE-GROUPS.
# Prints nothing (exits 1) if the file or group name is unknown/invalid.
function __wt_read_group
    test -f $__wt_worktree_home/WORKTREE-GROUPS; or return 1
    __wt_validate_group $argv[1]; or return 1
    set -l line (grep -E "^$argv[1]:" $__wt_worktree_home/WORKTREE-GROUPS | head -n1)
    test -n "$line"; or return 1
    string replace -r "^$argv[1]:[ \t]*" '' $line \
        | string split ' ' \
        | string match -rv '^$'
end

# __wt_save_group — write/refresh a group line (repos alphabetized).
# Replaces the line for the same name if present, else appends. Group name is
# validated (regex-safe) before writing.
function __wt_save_group
    set -l name $argv[1]
    set -l repos $argv[2..-1]
    __wt_validate_group $name; or begin
        echo "__wt_save_group: invalid group name '$name' (use [a-z0-9-])" >&2
        return 1
    end
    set -l line "$name: "(printf '%s\n' $repos | sort | string join ' ')
    mkdir -p $__wt_worktree_home
    if test -f $__wt_worktree_home/WORKTREE-GROUPS
        grep -v -E "^$name:" $__wt_worktree_home/WORKTREE-GROUPS \
            > $__wt_worktree_home/WORKTREE-GROUPS.tmp
        echo $line >> $__wt_worktree_home/WORKTREE-GROUPS.tmp
        mv $__wt_worktree_home/WORKTREE-GROUPS.tmp $__wt_worktree_home/WORKTREE-GROUPS
    else
        echo $line > $__wt_worktree_home/WORKTREE-GROUPS
    end
end

# __wt_resolve_repos — turn the parsed flags into the repo list (one per line).
#   $argv[1] = --repos CSV value (may be empty)
#   $argv[2] = -g group name (may be empty)
# Precedence: --repos > -g > current repo.
function __wt_resolve_repos
    if test -n "$argv[1]"
        __wt_split_repos $argv[1]
    else if test -n "$argv[2]"
        __wt_read_group $argv[2]
        or begin
            echo "__wt_resolve_repos: unknown group '$argv[2]'" >&2
            return 1
        end
    else
        __wt_repo_name
        or begin
            echo "__wt_resolve_repos: not inside a git repository" >&2
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

# --- shared per-idea python venv --------------------------------------------
# Each idea gets ONE venv at $__wt_venv_home/<idea> (default
# $__wt_worktree_home/.venvs/<idea>) that is the UNION of every participating
# repo's Python manifest. It is created on worktree-start, kept by
# worktree-stop, removed by worktree-rm, and auto-activated on cd (see
# __wt_maybe_activate_venv). uv is preferred; python3 + pip is the fallback.

# __wt_venv_path — absolute path of the shared venv for an idea.
function __wt_venv_path
    echo $__wt_venv_home/$argv[1]
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

# __wt_ensure_venv — create/refresh the shared per-idea venv as the union of
# every Python manifest in the repo set. uv-first, python3+pip fallback.
# With uv, re-syncs on every call (fast, self-heals set changes). With pip,
# installs only on create or --force (pip reinstall of grantha-data is slow).
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
    if command -sq uv
        if not test -d $venv
            echo "creating venv $venv (uv)" >&2
            uv venv $venv; or return 1
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
# worktree.
function __wt_idea_for_pwd
    set -l wt_home (path resolve $__wt_worktree_home 2>/dev/null)
    test -n "$wt_home"; or return 0
    set -l here (pwd -P)
    if string match -q -- "$wt_home/*/*" $here
        set -l rel (string replace -- "$wt_home/" '' $here)
        set -l parts (string split / $rel)
        if test (count $parts) -ge 2; and not test "$parts[1]" = (basename $__wt_venv_home)
            echo $parts[2]
        end
    end
end

# __wt_activate_idea — source the shared venv's activate.fish and record the
# active idea. No-op if the venv is missing; skips re-activation when this idea
# is already active (re-sourcing would duplicate the venv's PATH entry).
function __wt_activate_idea
    set -l idea $argv[1]
    set -q __wt_active_idea; and test "$__wt_active_idea" = "$idea"; and return 0
    set -l venv (__wt_venv_path $idea)
    if test -d $venv
        source $venv/bin/activate.fish
        set -g __wt_active_idea $idea
    end
end

# __wt_maybe_activate_venv — auto-activate the shared idea venv when cd'ing into
# (or within) any of the idea's worktrees; deactivate when leaving or switching
# ideas. Registered on every PWD change. `deactivate` (defined by activate.fish)
# erases itself when called, so every call is guarded by $__wt_active_idea (also
# checked via `functions -q deactivate`, in case a manual deactivate or a
# worktree-rm of the live venv already cleared it) and cleared right after.
function __wt_maybe_activate_venv --on-variable PWD
    set -q __wt_venv_home; or return 0
    set -l idea (__wt_idea_for_pwd)
    if test -n "$idea"
        if set -q __wt_active_idea
            if test "$__wt_active_idea" = "$idea"
                return 0
            end
            functions -q deactivate; and deactivate
            set -e __wt_active_idea
        end
        __wt_activate_idea $idea
    else if set -q __wt_active_idea
        functions -q deactivate; and deactivate
        set -e __wt_active_idea
    end
end
# worktree-start — create or resume a worktree for an idea, then cd into it.
#
# Idempotent: if the worktree dir already exists (and is a valid worktree for
# this idea/repo) it just cds in; if the branch exists but the worktree is gone
# it re-attaches; otherwise it creates a fresh branch off `main`. With --repos
# or -g it ensures every repo in the set, cds into the current repo's worktree
# (or the first in the set), and prints all the paired dirs. With --repos +
# --save NAME it persists the set as a group.
#
# Two-phase (mirrors worktree-merge): phase 0 validates the whole repo set
# (main clone exists, is a git repo, has local `main`, destination is either
# absent or a valid worktree for this idea/repo, an interpreter present — uv or
# python3 — if any repo has a Python manifest) BEFORE creating anything, so a
# missing repo cannot leave a partially-created idea. Phase 1 creates/attaches
# worktrees and provisions the shared per-idea venv ($__wt_venv_home/<idea>) as
# the union of every participating repo's Python manifests. cd'ing into a
# worktree then auto-activates that venv (see __wt_maybe_activate_venv).
#
# <idea> must satisfy <idea> == branch == one directory component (validated by
# __wt_validate_idea). `main` here means the LOCAL main branch — keeping it
# current (fetching origin) is the user's responsibility; this tool never
# fetches or pushes.
#
# Usage:   worktree-start [--repos=A,B,C | -g NAME] [--save NAME] <idea>
# Flags:   --repos=A,B,C  explicit repo set for this invocation (ephemeral)
#          -g NAME        named group from WORKTREE-GROUPS
#          --save NAME    with --repos, persist the set as group NAME
# Example: worktree-start --repos=grantha-explorer,grantha-data,ramayana \
#                          --save ramayana incorporate-ramayana-govindaraja
#
# Side effects: may run `npm install` (only when node_modules absent and a
# package.json exists); may create/populate the shared idea venv; may append to
# WORKTREE-GROUPS (with --save).
# Exit codes: 0 ok; 1 usage error, invalid idea, any phase-0 validation
# failure (nothing created in that case), or a venv-provisioning failure.
function worktree-start
    argparse 'repos=' 'g/group=' 'save=' -- $argv; or return 1
    if not set -q argv[1]
        echo "usage: worktree-start [--repos=A,B,C | -g NAME] [--save NAME] <idea>" >&2
        return 1
    end
    if set -q _flag_repos; and set -q _flag_group
        echo "worktree-start: --repos and -g are mutually exclusive" >&2
        return 1
    end
    if set -q _flag_save; and not set -q _flag_repos
        echo "worktree-start: --save requires --repos" >&2
        return 1
    end
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
    or begin
        echo "worktree-start: not inside a git repository" >&2
        return 1
    end
    set -l idea $argv[1]
    __wt_validate_idea $idea
    or begin
        echo "worktree-start: invalid idea name '$idea' (must be a single path component and a valid git branch name)" >&2
        return 1
    end
    set -l self (__wt_repo_name); or return 1
    set -l repos (__wt_resolve_repos "$_flag_repos" "$_flag_group"); or return 1
    # phase 0 — validate the whole set before mutating anything
    for repo in $repos
        set -l main_root $__wt_github_home/$repo
        set -l path $__wt_worktree_home/$repo/$idea
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
    # phase 1 — create/attach (all validated above)
    for repo in $repos
        set -l path $__wt_worktree_home/$repo/$idea
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
    if test (count $repos) -gt 1
        echo "paired worktrees:"
        for repo in $repos
            echo "  $__wt_worktree_home/$repo/$idea"
        end
    end
    if set -q _flag_save; and set -q _flag_repos
        __wt_save_group $_flag_save $repos
    end
    set -l target $self
    if not contains -- $self $repos
        set target $repos[1]
    end
    cd $__wt_worktree_home/$target/$idea
    # NOTE (known deficiency, see §12): install is hardcoded to npm and gated
    # only on package.json. Repos using pnpm/yarn/bun (lockfile:
    # pnpm-lock.yaml / yarn.lock / bun.lockb) are currently NOT auto-installed.
    if not test -d node_modules; and test -f package.json
        npm install
    end
    git status -sb
    git plan
end
# worktree-go — cd into this repo's worktree for an idea and refresh context.
#
# Usage:   worktree-go <idea>
# Example: worktree-go whitespace-normalization
# Exit codes: 0 ok; 1 usage error, unknown idea, or not a worktree.
function worktree-go
    if not set -q argv[1]
        echo "usage: worktree-go <idea>" >&2
        return 1
    end
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
    or begin
        echo "worktree-go: not inside a git repository" >&2
        return 1
    end
    set -l idea $argv[1]
    __wt_validate_idea $idea
    or begin
        echo "worktree-go: invalid idea name '$idea'" >&2
        return 1
    end
    set -l self (__wt_repo_name); or return 1
    set -l path $__wt_worktree_home/$self/$idea
    test -d $path
    or begin
        echo "worktree-go: no worktree at $path" >&2
        return 1
    end
    cd $path
    git status -sb
    git plan
end
# worktree-merge — integrate a finished idea into main via rebase + fast-forward.
#
# Three phases, coordinated across the repo set (NOT a cross-repo transaction —
# per-repo atomicity only; see Known limitations):
#   phase 0  preflight every repo (worktree exists; main clone clean & on
#            'main'; worktree clean) — abort before touching anything
#   phase 1  rebase each branch onto main (abort before any merge on failure)
#   phase 2  --ff-only merge each into its own main
# Does NOT push. Leaves each branch checked out in its worktree.
#
# Usage:   worktree-merge [--repos=A,B,C | -g NAME] <idea>
# Example: worktree-merge -g ramayana incorporate-ramayana-govindaraja
# Exit codes: 0 ok; 1 usage error or any phase failure. On a phase-1 failure no
# main branch has been merged, but some idea branches may already have been
# rebased (no rollback — see Known limitations). A phase-2 failure is unexpected
# but still possible (hooks, locks, concurrent state changes); it is not
# "impossible", just unusual.
function worktree-merge
    argparse 'repos=' 'g/group=' -- $argv; or return 1
    if not set -q argv[1]
        echo "usage: worktree-merge [--repos=A,B,C | -g NAME] <idea>" >&2
        return 1
    end
    if set -q _flag_repos; and set -q _flag_group
        echo "worktree-merge: --repos and -g are mutually exclusive" >&2
        return 1
    end
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
    or begin
        echo "worktree-merge: not inside a git repository" >&2
        return 1
    end
    set -l idea $argv[1]
    __wt_validate_idea $idea
    or begin
        echo "worktree-merge: invalid idea name '$idea'" >&2
        return 1
    end
    set -l repos (__wt_resolve_repos "$_flag_repos" "$_flag_group"); or return 1
    # phase 0 — preflight everything before touching any main
    for repo in $repos
        set -l main_root $__wt_github_home/$repo
        set -l path $__wt_worktree_home/$repo/$idea
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
        set -l path $__wt_worktree_home/$repo/$idea
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
    echo "remember to push origin/main in each repo"
end
# worktree-stop — park a worktree: remove the dir but keep the branch.
#
# Refuses when the worktree has uncommitted changes unless --force (which
# discards them). Cds to each repo's main root before removing so the shell
# never dangles inside a removed dir.
#
# Usage:   worktree-stop [--repos=A,B,C | -g NAME] [--force] <idea>
# Flags:   --force  discard uncommitted changes and remove anyway
# Exit codes: 0 ok; 1 usage error, dirty worktree (no --force), or not in a repo.
function worktree-stop
    argparse 'repos=' 'g/group=' 'f/force' -- $argv; or return 1
    if not set -q argv[1]
        echo "usage: worktree-stop [--repos=A,B,C | -g NAME] [--force] <idea>" >&2
        return 1
    end
    if set -q _flag_repos; and set -q _flag_group
        echo "worktree-stop: --repos and -g are mutually exclusive" >&2
        return 1
    end
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
    or begin
        echo "worktree-stop: not inside a git repository" >&2
        return 1
    end
    set -l idea $argv[1]
    __wt_validate_idea $idea
    or begin
        echo "worktree-stop: invalid idea name '$idea'" >&2
        return 1
    end
    set -l repos (__wt_resolve_repos "$_flag_repos" "$_flag_group"); or return 1
    for repo in $repos
        set -l path $__wt_worktree_home/$repo/$idea
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
    echo "update WORKTREES.md rows if parked"
end
# worktree-rm — tear down a worktree and delete its branch.
#
# Removes the worktree first (git refuses branch deletion while a worktree is
# live), then deletes the branch safe-first: `git branch -d`; if the branch is
# not merged into main, prompts for a second confirmation before `git branch -D`.
# Finally removes the shared idea venv (recreatable on next start; prompts
# before removing). Refuses when dirty unless --force.
#
# Usage:   worktree-rm [--repos=A,B,C | -g NAME] [--force] <idea>
# Flags:   --force  discard uncommitted changes and remove anyway
# Exit codes: 0 ok; 1 usage error, dirty worktree (no --force), or not in a repo.
function worktree-rm
    argparse 'repos=' 'g/group=' 'f/force' -- $argv; or return 1
    if not set -q argv[1]
        echo "usage: worktree-rm [--repos=A,B,C | -g NAME] [--force] <idea>" >&2
        return 1
    end
    if set -q _flag_repos; and set -q _flag_group
        echo "worktree-rm: --repos and -g are mutually exclusive" >&2
        return 1
    end
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
    or begin
        echo "worktree-rm: not inside a git repository" >&2
        return 1
    end
    set -l idea $argv[1]
    __wt_validate_idea $idea
    or begin
        echo "worktree-rm: invalid idea name '$idea'" >&2
        return 1
    end
    set -l repos (__wt_resolve_repos "$_flag_repos" "$_flag_group"); or return 1
    for repo in $repos
        set -l path $__wt_worktree_home/$repo/$idea
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
    # teardown the shared idea venv (recreatable on next start)
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
    echo "update WORKTREES.md — remove $idea rows"
end
# worktree-list — global recall: enumerate every worktree + registry across all
# repos under $__wt_worktree_home. No repo needed; no flags.
#
# Usage:   worktree-list
# Exit codes: 0 always (best-effort).
function worktree-list
    for repo in $__wt_worktree_home/*
        test -d $repo; or continue
        set -l name (basename $repo)
        if test "$name" = (basename $__wt_venv_home)
            continue   # shared venv dir is not a repo
        end
        echo "== $name =="
        git -C $__wt_github_home/$name worktree list 2>/dev/null
        echo
        if git -C $__wt_github_home/$name cat-file -e main:WORKTREES.md 2>/dev/null
            git -C $__wt_github_home/$name show main:WORKTREES.md 2>/dev/null | sed -n '1,30p'
        else
            echo "(no WORKTREES.md on main)"
        end
        echo
    end
end
# worktree-venv — ensure/refresh the shared per-idea venv for a repo set.
#
# The venv is the UNION of every Python manifest in the set (pyproject -> -e,
# else requirements.txt). uv-first, python3+pip fallback; uv re-syncs each call,
# pip installs on create or --force. Prints the venv path. If the current PWD
# is inside one of the idea's worktrees, activates the venv for this shell.
#
# Usage:   worktree-venv [--repos=A,B,C | -g NAME] [--force] <idea>
# Flags:   --repos=A,B,C  explicit repo set for this invocation (ephemeral)
#          -g NAME        named group from WORKTREE-GROUPS
#          --force        with pip fallback, reinstall even if venv exists
# Exit codes: 0 ok; 1 usage error, invalid idea, unknown group, or no Python
# manifests in the set.
function worktree-venv
    argparse 'repos=' 'g/group=' 'f/force' -- $argv; or return 1
    if not set -q argv[1]
        echo "usage: worktree-venv [--repos=A,B,C | -g NAME] [--force] <idea>" >&2
        return 1
    end
    if set -q _flag_repos; and set -q _flag_group
        echo "worktree-venv: --repos and -g are mutually exclusive" >&2
        return 1
    end
    set -l idea $argv[1]
    __wt_validate_idea $idea
    or begin
        echo "worktree-venv: invalid idea name '$idea'" >&2
        return 1
    end
    set -l repos (__wt_resolve_repos "$_flag_repos" "$_flag_group"); or return 1
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
        __wt_activate_idea $idea
    end
end
# --- completions ------------------------------------------------------------
function __fish_print_worktrees
    path basename $__wt_worktree_home/(__wt_repo_name)/* 2>/dev/null
end

function __fish_print_groups
    test -f $__wt_worktree_home/WORKTREE-GROUPS; or return
    string replace -r ':.*' '' < $__wt_worktree_home/WORKTREE-GROUPS
end

complete -c worktree-start -f -a '(__fish_print_worktrees)'
complete -c worktree-start -s g -l group -r -a '(__fish_print_groups)' -d 'repo group from WORKTREE-GROUPS'
complete -c worktree-start -l repos -r -d 'explicit repo set A,B,C'
complete -c worktree-start -l save -r -d 'save --repos as a named group'
complete -c worktree-go -f -a '(__fish_print_worktrees)'
complete -c worktree-merge -f -a '(__fish_print_worktrees)'
complete -c worktree-merge -s g -l group -r -a '(__fish_print_groups)' -d 'repo group from WORKTREE-GROUPS'
complete -c worktree-merge -l repos -r -d 'explicit repo set A,B,C'
complete -c worktree-stop -f -a '(__fish_print_worktrees)'
complete -c worktree-stop -s g -l group -r -a '(__fish_print_groups)' -d 'repo group from WORKTREE-GROUPS'
complete -c worktree-stop -l repos -r -d 'explicit repo set A,B,C'
complete -c worktree-stop -s f -l force -d 'discard uncommitted changes'
complete -c worktree-rm -f -a '(__fish_print_worktrees)'
complete -c worktree-rm -s g -l group -r -a '(__fish_print_groups)' -d 'repo group from WORKTREE-GROUPS'
complete -c worktree-rm -l repos -r -d 'explicit repo set A,B,C'
complete -c worktree-rm -s f -l force -d 'discard uncommitted changes'
complete -c worktree-venv -f -a '(__fish_print_worktrees)'
complete -c worktree-venv -s g -l group -r -a '(__fish_print_groups)' -d 'repo group from WORKTREE-GROUPS'
complete -c worktree-venv -l repos -r -d 'explicit repo set A,B,C'
complete -c worktree-venv -s f -l force -d 'reinstall deps / rebuild venv'
complete -c worktree-list -f
