#!/usr/bin/env bash
# test.sh — automated lifecycle test for the worktrees tooling.
#
# Builds throwaway repos in a temp dir, runs configure+install against a temp
# HOME, then exercises the fish functions and git plan against the sandbox.
# Fails (nonzero) if any assertion fails. Safe to run anywhere; cleans up.
#
# Coverage: start / idempotent restart / multi-repo / missing-repo preflight /
# invalid idea / bogus destination / go / git plan / merge refusals / coordinated
# merge / stop+resume / rm / shared python venv (union resolution, auto-activation,
# pip fallback, python3 fast-fail) / repo-local .venv auto-activation (incl. the
# inherited-PATH clobber regression) / JS deps / any-directory invocation /
# description registry seeding (incl. old-schema auto-migration + idempotency) /
# interactive prompting (idea/repos/description,
# --save prompt, lifecycle idea prompts, --help) / environment fast-fail guards.
# Interactive tests use run_fish_in (pipes answers + __wt_force_prompt); every
# other test runs with stdin pinned to /dev/null (non-interactive).
# All installs are offline (manifests are dependency-free); the `.python-version`
# pin tests additionally require `uv` and a local non-3.13 interpreter (or are
# skipped).
#
# Usage:   ./test.sh
# no `-e` on purpose: run_fish + ok/fail manage status explicitly; `-e` would
# abort mid-harness on the first expected failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d /tmp/wt-test.XXXXXX)" || { echo "mktemp failed" >&2; exit 1; }
# exported so the fish subshells (run_fish) can reference temp paths
export WORK
GITHUB_HOME="$WORK/github"
WT_HOME="$WORK/wt"

trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# run_fish <label> <script> — run fish with the tooling loaded and a temp HOME.
# stdin is pinned to /dev/null so the fish process is always NON-interactive:
# otherwise running ./test.sh from a terminal would make the harness a tty and
# every no-flags command would block on a prompt. The trailing `exit 0` makes
# the overall rc deterministic: any mid-script `exit 1` still aborts, but an
# assertion that correctly fails (e.g. a command that must fail) no longer
# leaks its nonzero status into the final rc.
run_fish() {
    local label="$1" script="$2"
    local out
    out="$(HOME="$WORK/home" fish -c "
        set -gx XDG_CONFIG_HOME \"\$HOME/.config\"
        for v in VIRTUAL_ENV VIRTUAL_ENV_PROMPT _OLD_VIRTUAL_PATH _OLD_VIRTUAL_PYTHONHOME _OLD_FISH_PROMPT_OVERRIDE
            set -q \$v; and set -e \$v
        end
        source \$XDG_CONFIG_HOME/fish/conf.d/worktrees-config.fish
        source \$XDG_CONFIG_HOME/fish/conf.d/worktrees.fish
        $script
        exit 0
    " 2>&1 </dev/null)"
    local rc=$?
    if [ $rc -eq 0 ]; then ok "$label"; else
        fail "$label (rc=$rc)"
        printf '      %s\n' "$out" | sed 's/^/        /'
    fi
}

# run_fish_in <label> <stdin> <script> — like run_fish, but feeds `<stdin>`
# lines to the fish process and forces interactive prompting (`__wt_force_prompt
# 1`, the documented test hook) so the prompt tests can drive idea/repos/
# description answers deterministically from a pipe. Reads past the pipe get EOF
# (empty), so each prompt test must supply at least as many lines as prompts.
run_fish_in() {
    local label="$1" stdin="$2" script="$3"
    local out
    out="$(printf '%s\n' "$stdin" | HOME="$WORK/home" fish -c "
        set -gx XDG_CONFIG_HOME \"\$HOME/.config\"
        for v in VIRTUAL_ENV VIRTUAL_ENV_PROMPT _OLD_VIRTUAL_PATH _OLD_VIRTUAL_PYTHONHOME _OLD_FISH_PROMPT_OVERRIDE
            set -q \$v; and set -e \$v
        end
        set -g __wt_force_prompt 1
        source \$XDG_CONFIG_HOME/fish/conf.d/worktrees-config.fish
        source \$XDG_CONFIG_HOME/fish/conf.d/worktrees.fish
        $script
        exit 0
    " 2>&1)"
    local rc=$?
    if [ $rc -eq 0 ]; then ok "$label"; else
        fail "$label (rc=$rc)"
        printf '      %s\n' "$out" | sed 's/^/        /'
    fi
}

echo "== setup: throwaway repos + config/install into temp HOME =="

mkdir -p "$GITHUB_HOME" "$WORK/home"
for r in repo-a repo-b; do
    git init -q -b main "$GITHUB_HOME/$r"
    git -C "$GITHUB_HOME/$r" config user.email t@t
    git -C "$GITHUB_HOME/$r" config user.name t
    echo base > "$GITHUB_HOME/$r/base.txt"
    git -C "$GITHUB_HOME/$r" add -A
    git -C "$GITHUB_HOME/$r" commit -qm base
done

# python repos for shared-venv coverage — manifests are dependency-free so all
# installs are offline and instant
for r in repo-req repo-req2 repo-py repo-pin; do
    git init -q -b main "$GITHUB_HOME/$r"
    git -C "$GITHUB_HOME/$r" config user.email t@t
    git -C "$GITHUB_HOME/$r" config user.name t
    echo base > "$GITHUB_HOME/$r/base.txt"
    git -C "$GITHUB_HOME/$r" add -A
    git -C "$GITHUB_HOME/$r" commit -qm base
done
# repo-req / repo-req2 -> requirements.txt only; repo-py -> BOTH pyproject.toml
# and requirements.txt (pyproject must win the union resolution)
echo '# offline: no deps' > "$GITHUB_HOME/repo-req/requirements.txt"
echo '# offline: no deps' > "$GITHUB_HOME/repo-req2/requirements.txt"
echo '# offline: no deps' > "$GITHUB_HOME/repo-py/requirements.txt"
cat > "$GITHUB_HOME/repo-py/pyproject.toml" <<'EOF'
[project]
name = "testpkg"
version = "0.0.1"
dependencies = []
EOF
# repo-pin -> dependency-free pyproject PLUS a .python-version interpreter pin.
# Used to exercise the pin honoring and wrong-minor recreation. The pin
# ($PIN_VERSION) must resolve to an installed interpreter; uv picks it from the
# real system Pythons.
cat > "$GITHUB_HOME/repo-pin/pyproject.toml" <<'EOF'
[project]
name = "testpkg-pin"
version = "0.0.1"
dependencies = []
EOF
PIN_VERSION=3.13
echo "$PIN_VERSION" > "$GITHUB_HOME/repo-pin/.python-version"
for r in repo-req repo-req2 repo-py repo-pin; do
    git -C "$GITHUB_HOME/$r" add -A
    git -C "$GITHUB_HOME/$r" commit -qm python-manifests
done

# a repo-local .venv in repo-a (main clone) for the repo-venv auto-activation
# coverage — a minimal, offline activate.fish that mirrors the real template's
# deactivate/snapshot behavior (no python3 or uv needed).
mkdir -p "$GITHUB_HOME/repo-a/.venv/bin"
cat > "$GITHUB_HOME/repo-a/.venv/bin/activate.fish" <<EOF
function deactivate  -d "Exit virtual environment and return to normal shell environment"
    if test -n "\$_OLD_VIRTUAL_PATH"
        set -gx PATH \$_OLD_VIRTUAL_PATH
        set -e _OLD_VIRTUAL_PATH
    end
    set -e VIRTUAL_ENV
    set -e VIRTUAL_ENV_PROMPT
    if test "\$argv[1]" != "nondestructive"
        functions -e deactivate
    end
end
deactivate nondestructive
set -gx VIRTUAL_ENV "$GITHUB_HOME/repo-a/.venv"
set -gx _OLD_VIRTUAL_PATH \$PATH
set -gx PATH "\$VIRTUAL_ENV/bin" \$PATH
set -gx VIRTUAL_ENV_PROMPT repo-a
EOF

# js repos for node-deps coverage — no Python manifests, so venv provisioning
# no-ops. repo-js: package.json + lockfile (npm ci); repo-js-bare: package.json
# only (npm install); repo-pnpm: package.json + pnpm lockfile (pnpm install).
for r in repo-js repo-js-bare repo-pnpm; do
    git init -q -b main "$GITHUB_HOME/$r"
    git -C "$GITHUB_HOME/$r" config user.email t@t
    git -C "$GITHUB_HOME/$r" config user.name t
    echo base > "$GITHUB_HOME/$r/base.txt"
    git -C "$GITHUB_HOME/$r" add -A
    git -C "$GITHUB_HOME/$r" commit -qm base
done
echo '{"name":"repo-js","version":"0.0.1"}' > "$GITHUB_HOME/repo-js/package.json"
echo '{}' > "$GITHUB_HOME/repo-js/package-lock.json"
echo '{"name":"repo-js-bare","version":"0.0.1"}' > "$GITHUB_HOME/repo-js-bare/package.json"
echo '{"name":"repo-pnpm","version":"0.0.1"}' > "$GITHUB_HOME/repo-pnpm/package.json"
touch "$GITHUB_HOME/repo-pnpm/pnpm-lock.yaml"
for r in repo-js repo-js-bare repo-pnpm; do
    git -C "$GITHUB_HOME/$r" add -A
    git -C "$GITHUB_HOME/$r" commit -qm js-manifests
done

# a PATH dir with git but NO python3/uv, for the python3 fast-fail test
export WT_TESTBIN="$WORK/testbin"; mkdir -p "$WT_TESTBIN"
ln -sf /usr/bin/git "$WT_TESTBIN/git"

# a PATH dir of fake JS package managers that record calls to npm-calls.log and
# fake a node_modules dir after install (all offline, instant, no side effects)
export WT_NODEBIN="$WORK/nodebin"; mkdir -p "$WT_NODEBIN"
for m in npm pnpm yarn bun; do
    cat > "$WT_NODEBIN/$m" <<EOF
#!/bin/sh
echo "\$(basename \$0) \$@" >> "$WT_NODEBIN/npm-calls.log"
mkdir -p node_modules
exit 0
EOF
    chmod +x "$WT_NODEBIN/$m"
done

# global idea registry at $WT_HOME/WORKTREES.md so `git plan` has a row to
# match (previously a per-repo committed WORKTREES.md on repo-a main)
mkdir -p "$WT_HOME"
cat > "$WT_HOME/WORKTREES.md" <<EOF
# Worktrees

| Idea | Branch | Repos | Description | Plan file | Status |
|---|---|---|---|---|---|
| \`idea-one\` | \`idea-one\` | repo-a | Test idea | Test idea one | active |
EOF

# configure (answer defaults) + install — fail loudly, don't cascade
if ! printf "%s\n%s\n" "$GITHUB_HOME" "$WT_HOME" | HOME="$WORK/home" bash "$ROOT/configure.sh" >/dev/null 2>&1; then
    echo "test.sh: configure.sh failed during setup" >&2
    exit 1
fi
if ! HOME="$WORK/home" bash "$ROOT/install.sh" >/dev/null 2>&1; then
    echo "test.sh: install.sh failed during setup" >&2
    exit 1
fi

echo "== lifecycle =="

run_fish "start creates worktree on idea branch" '
    cd "$__wt_github_home/repo-a"
    worktree-start idea-one >/dev/null 2>&1; or exit 1
    test (git branch --show-current) = idea-one; or exit 1
    test -d "$__wt_worktree_home/idea-one/repo-a"; or exit 1
    not test -d "$__wt_worktree_home/repo-a/idea-one"; or exit 1   # old repo-first layout never created
'

run_fish "start is idempotent (re-run ok)" '
    cd "$__wt_github_home/repo-a"
    worktree-start idea-one >/dev/null 2>&1; or exit 1
'

run_fish "multi-repo start creates both worktrees" '
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-a,repo-b idea-two >/dev/null 2>&1; or exit 1
    test -d "$__wt_worktree_home/idea-two/repo-b"; or exit 1
'

run_fish "missing repo preflights (creates nothing)" '
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-a,ghost idea-three >/dev/null 2>&1; and exit 1
    not test -d "$__wt_worktree_home/idea-three/repo-a"; or exit 1
'

run_fish "invalid idea rejected" '
    cd "$__wt_github_home/repo-a"
    worktree-start "foo/bar" >/dev/null 2>&1; and exit 1
'

run_fish "existing bogus destination rejected" '
    cd "$__wt_github_home/repo-a"
    mkdir -p "$__wt_worktree_home/bogus/repo-a"
    worktree-start bogus >/dev/null 2>&1; and exit 1
'

run_fish "go enters this repo worktree" '
    cd "$__wt_github_home/repo-a"
    worktree-go idea-one >/dev/null 2>&1; or exit 1
    test (basename (dirname (pwd))) = idea-one; or exit 1   # idea-first: parent is the idea
'

run_fish "git plan matches registry row" '
    cd "$__wt_worktree_home/idea-one/repo-a"
    set -l row (git plan 2>/dev/null | string match -r "idea-one.*Test idea one"); or exit 1
'

run_fish "merge refuses dirty main" '
    cd "$__wt_github_home/repo-a"
    echo dirty >> base.txt   # dirty main
    worktree-merge idea-one >/dev/null 2>&1; and exit 1
    git checkout -q -- base.txt; or exit 1
'

run_fish "merge refuses when main clone not on main" '
    cd "$__wt_github_home/repo-a"
    git checkout -q -b side 2>/dev/null; or true
    worktree-merge idea-one >/dev/null 2>&1; and exit 1
    git checkout -q main; or exit 1
'

run_fish "coordinated merge fast-forwards main" '
    cd "$__wt_github_home/repo-a"
    git -C "$__wt_worktree_home/idea-one/repo-a" commit -q --allow-empty -m wip
    worktree-merge idea-one >/dev/null 2>&1; or exit 1
    git merge-base --is-ancestor idea-one main; or exit 1
'

run_fish "stop removes dir, keeps branch" '
    cd "$__wt_github_home/repo-a"
    worktree-stop idea-one >/dev/null 2>&1; or exit 1
    not test -d "$__wt_worktree_home/idea-one/repo-a"; or exit 1
    git branch --list idea-one | string match -q "*idea-one"; or exit 1
'

run_fish "stop refuses dirty worktree without --force" '
    cd "$__wt_github_home/repo-a"
    worktree-start idea-one >/dev/null 2>&1
    echo wip >> "$__wt_worktree_home/idea-one/repo-a/base.txt"
    worktree-stop idea-one >/dev/null 2>&1; and exit 1
    worktree-stop --force idea-one >/dev/null 2>&1; or exit 1
    not test -d "$__wt_worktree_home/idea-one/repo-a"; or exit 1
'

run_fish "resume re-attaches parked branch" '
    cd "$__wt_github_home/repo-a"
    worktree-start idea-one >/dev/null 2>&1; or exit 1
    test (git branch --show-current) = idea-one; or exit 1
'

run_fish "rm removes worktree and merged branch" '
    cd "$__wt_github_home/repo-a"
    worktree-rm idea-one </dev/null >/dev/null 2>&1; or exit 1
    not test -d "$__wt_worktree_home/idea-one/repo-a"; or exit 1
    not git branch --list idea-one | string match -q "*idea-one"; or exit 1
'

echo "== idea-first layout =="

run_fish "__wt_wt_path is the single layout source (idea-first)" '
    test (__wt_wt_path idea-helper repo-a) = "$__wt_worktree_home/idea-helper/repo-a"; or exit 1
    test (__wt_wt_path some-idea repo-b) = "$__wt_worktree_home/some-idea/repo-b"; or exit 1
'

run_fish "__wt_idea_for_pwd resolves the idea from a new-layout subdir" '
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-a idea-helper >/dev/null 2>&1; or exit 1
    mkdir -p "$__wt_worktree_home/idea-helper/repo-a/sub"
    cd "$__wt_worktree_home/idea-helper/repo-a/sub"
    test (__wt_idea_for_pwd) = idea-helper; or exit 1
'

run_fish "worktree-list groups worktrees by idea" '
    set -l out (worktree-list 2>/dev/null)
    string match -q "*== idea-helper ==*" "$out"; or exit 1
    string match -q "*idea-helper*repo-a*" "$out"; or exit 1
'

run_fish "worktree-list is best-effort with a missing worktree home" '
    set -l saved $__wt_worktree_home
    set -g __wt_worktree_home "$WORK/nonexistent-wt"
    worktree-list >/dev/null 2>&1; or exit 1
    set -g __wt_worktree_home $saved
'

run_fish "__fish_print_worktrees completes all ideas (not repo names) from any cwd" '
    cd "$__wt_github_home/repo-a"
    set -l ideas (__fish_print_worktrees)
    contains -- idea-helper $ideas; or exit 1
    not contains -- repo-a $ideas; or exit 1
    cd "$WORK/home"   # neutral dir, not a repo
    set -l ideas (__fish_print_worktrees)
    contains -- idea-helper $ideas; or exit 1
    not contains -- repo-a $ideas; or exit 1
'

run_fish "go works from a neutral directory (falls back to a participating repo)" '
    cd "$WORK/home"   # not a git repo
    worktree-go idea-helper >/dev/null 2>&1; or exit 1
    test (basename (dirname (pwd))) = idea-helper; or exit 1
    test (basename (pwd)) = repo-a; or exit 1
'

echo "== shared python venv =="

run_fish "pyproject wins over requirements.txt (arg resolution)" '
    set -l args (__wt_venv_args repo-py)
    contains -- -e $args; or exit 1
    contains -- "$__wt_github_home/repo-py" $args; or exit 1
    not contains -- -r $args; or exit 1
    not contains -- "$__wt_github_home/repo-py/requirements.txt" $args; or exit 1
'

run_fish "union venv from multiple manifests, auto-activated on cd" '
    cd "$__wt_github_home/repo-req"
    worktree-start --repos=repo-req,repo-req2 idea-python >/dev/null 2>&1; or exit 1
    test -d "$__wt_venv_home/idea-python"; or exit 1
    test -x "$__wt_venv_home/idea-python/bin/python"; or exit 1
    test -n "$VIRTUAL_ENV"; or exit 1
'

run_fish "venv deactivates on leaving, swaps on idea switch, works in subdirs" '
    cd "$__wt_worktree_home/idea-python/repo-req"
    test -n "$VIRTUAL_ENV"; or exit 1
    mkdir -p "$__wt_worktree_home/idea-python/repo-req/sub"
    cd "$__wt_worktree_home/idea-python/repo-req/sub"
    test -n "$VIRTUAL_ENV"; or exit 1
    cd "$__wt_github_home/repo-req"
    test -z "$VIRTUAL_ENV"; or exit 1
    worktree-start --repos=repo-req idea-python2 >/dev/null 2>&1; or exit 1
    cd "$__wt_worktree_home/idea-python/repo-req"
    test -n "$VIRTUAL_ENV"; or exit 1
    cd "$__wt_worktree_home/idea-python2/repo-req"
    string match -q "*idea-python2" "$VIRTUAL_ENV"; or exit 1
'

run_fish "worktree-venv prints the venv path" '
    cd "$__wt_github_home/repo-req"
    set -l out (worktree-venv --repos=repo-req idea-python2 2>/dev/null)
    string match -q "*idea-python2" $out; or exit 1
'

run_fish "stop keeps venv, rm removes it" '
    cd "$__wt_github_home/repo-req"
    worktree-stop --repos=repo-req,repo-req2 idea-python >/dev/null 2>&1; or exit 1
    test -d "$__wt_venv_home/idea-python"; or exit 1
    worktree-rm --repos=repo-req,repo-req2 idea-python </dev/null >/dev/null 2>&1; or exit 1
    not test -d "$__wt_venv_home/idea-python"; or exit 1
'

run_fish "pip fallback creates venv when uv absent" '
    cd "$__wt_github_home/repo-req"
    set -gx PATH /usr/bin:/usr/local/bin
    command -sq uv; and exit 1
    worktree-start --repos=repo-req idea-pip >/dev/null 2>&1; or exit 1
    test -d "$__wt_venv_home/idea-pip"; or exit 1
    test -x "$__wt_venv_home/idea-pip/bin/python"; or exit 1
    test -x "$__wt_venv_home/idea-pip/bin/pip"; or exit 1
'

run_fish "python3 missing fast-fails phase 0 (nothing created)" '
    cd "$__wt_github_home/repo-req"
    set -gx PATH "$WT_TESTBIN:/usr/local/bin:/bin:/usr/sbin"
    command -sq python3; and exit 1
    worktree-start --repos=repo-req,repo-req2 idea-nopython >/dev/null 2>&1; and exit 1
    not test -d "$__wt_venv_home/idea-nopython"; or exit 1
    not test -d "$__wt_worktree_home/idea-nopython/repo-req"; or exit 1
'

PIN_VERSION=3.13
if command -v uv >/dev/null 2>&1; then
run_fish ".python-version pin: venv is created on the pinned minor" '
    cd "$__wt_github_home/repo-pin"
    worktree-start --repos=repo-pin idea-repin >/dev/null 2>&1; or exit 1
    set -l v ($__wt_venv_home/idea-repin/bin/python -c "import sys; print(f\"{sys.version_info[0]}.{sys.version_info[1]}\")" 2>/dev/null)
    test "$v" = "'"$PIN_VERSION"'"; or exit 1
'

run_fish ".python-version pin: wrong-minor venv is recreated to the pin" '
    set -l other (uv python find --no-project --system "<=3.12" 2>/dev/null)
    test -n "$other"; or exit 0   # no non-pinned system Python: branch untestable, skip
    uv venv --python $other $__wt_venv_home/idea-mismatch 2>/dev/null; or exit 1
    set -l before ($__wt_venv_home/idea-mismatch/bin/python -c "import sys; print(f\"{sys.version_info[0]}.{sys.version_info[1]}\")" 2>/dev/null)
    test "$before" != "'"$PIN_VERSION"'"; or exit 1
    __wt_ensure_venv idea-mismatch repo-pin >/dev/null 2>&1; or exit 1
    set -l after ($__wt_venv_home/idea-mismatch/bin/python -c "import sys; print(f\"{sys.version_info[0]}.{sys.version_info[1]}\")" 2>/dev/null)
    test "$after" = "'"$PIN_VERSION"'"; or exit 1
'
else
    echo "  skip  .python-version pin tests (uv not on PATH)"
fi

echo "== repo-local .venv auto-activation =="

run_fish "repo .venv activates on cd into main clone, holds in subdirs" '
    cd "$__wt_github_home/repo-a"
    string match -q "*/repo-a/.venv" "$VIRTUAL_ENV"; or exit 1
    mkdir -p "$__wt_github_home/repo-a/sub"
    cd "$__wt_github_home/repo-a/sub"
    string match -q "*/repo-a/.venv" "$VIRTUAL_ENV"; or exit 1
'

run_fish "repo .venv deactivates on leaving to a repo with none" '
    cd "$__wt_github_home/repo-a"
    test -n "$VIRTUAL_ENV"; or exit 1
    cd "$__wt_github_home/repo-b"
    test -z "$VIRTUAL_ENV"; or exit 1
'

run_fish "clobber regression: stale inherited venv state preserves PATH" '
    mkdir -p "$WORK/sentinel"
    cd "$__wt_github_home/repo-b"
    set -gx VIRTUAL_ENV "$WORK/ghost-venv"
    set -gx _OLD_VIRTUAL_PATH "/usr/bin"
    set -gx PATH "$WORK/sentinel" $PATH
    cd "$__wt_github_home/repo-a"
    string match -q "*/repo-a/.venv" "$VIRTUAL_ENV"; or exit 1
    string match -q "*$WORK/sentinel*" "$PATH"; or exit 1
    not string match -q "*ghost-venv/bin*" "$PATH"; or exit 1
'

run_fish "re-asserts fish_user_paths (bun/.local pattern) through venv cycle" '
    mkdir -p "$WORK/fap-sentinel"
    fish_add_path "$WORK/fap-sentinel"
    set -gx PATH "/usr/bin"
    set -gx VIRTUAL_ENV "$WORK/ghost-venv"
    set -gx _OLD_VIRTUAL_PATH "/usr/bin"
    cd "$__wt_github_home/repo-a"
    string match -q "*$WORK/fap-sentinel*" "$PATH"; or exit 1
    cd "$__wt_github_home/repo-b"
    string match -q "*$WORK/fap-sentinel*" "$PATH"; or exit 1
'

run_fish "main clone .venv and shared idea venv swap cleanly (no PATH dup)" '
    cd "$__wt_github_home/repo-req"
    worktree-start --repos=repo-req idea-rvswap >/dev/null 2>&1; or exit 1
    cd "$__wt_github_home/repo-req"
    test -z "$VIRTUAL_ENV"; or exit 1
    cd "$__wt_worktree_home/idea-rvswap/repo-req"
    test -n "$VIRTUAL_ENV"; or exit 1
    test (count (string match -- "$__wt_venv_home/idea-rvswap/bin" $PATH)) -le 1; or exit 1
    cd "$__wt_github_home/repo-a"
    string match -q "*/repo-a/.venv" "$VIRTUAL_ENV"; or exit 1
    test (count (string match -- "*/repo-a/.venv/bin" $PATH)) -le 1; or exit 1
'

run_fish "worktree with no .venv (no python manifest) stays un-activated" '
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-a idea-rvbare >/dev/null 2>&1; or exit 1
    cd "$__wt_worktree_home/idea-rvbare/repo-a"
    test -z "$VIRTUAL_ENV"; or exit 1
'

run_fish "venv-activate is idempotent and PATH-preserving" '
    cd "$__wt_github_home/repo-b"
    test -z "$VIRTUAL_ENV"; or exit 1
    venv-activate "$__wt_github_home/repo-a/.venv"; or exit 1
    test -n "$VIRTUAL_ENV"; or exit 1
    set -l before (string join : $PATH)
    venv-activate "$__wt_github_home/repo-a/.venv"; or exit 1
    set -l after (string join : $PATH)
    test "$before" = "$after"; or exit 1
'

run_fish "toggle off disables repo .venv auto-activation" '
    cd "$__wt_github_home/repo-b"
    set -g __wt_auto_repo_venv 0
    cd "$__wt_github_home/repo-a"
    test -z "$VIRTUAL_ENV"; or exit 1
    cd "$__wt_github_home/repo-b"
    set -g __wt_auto_repo_venv 1
    cd "$__wt_github_home/repo-a"
    string match -q "*/repo-a/.venv" "$VIRTUAL_ENV"; or exit 1
'

echo "== any-directory invocation =="

run_fish "start from a neutral dir with --repos + --description" '
    cd "$WORK/home"
    worktree-start --repos=repo-a,repo-b --description="neutral idea" idea-anydir >/dev/null 2>&1; or exit 1
    test -d "$__wt_worktree_home/idea-anydir/repo-a"; or exit 1
    test -d "$__wt_worktree_home/idea-anydir/repo-b"; or exit 1
    string match -r "idea-anydir.*neutral idea" (cat "$__wt_worktree_home/WORKTREES.md"); or exit 1
'

run_fish "neutral dir, no flags, non-interactive errors with a --repos hint" '
    cd "$WORK/home"
    set -l out (worktree-start idea-none 2>&1)
    test $status -eq 1; or exit 1
    string match -q "*--repos*" "$out"; or exit 1
'

run_fish "merge/stop/rm with explicit repos from a neutral dir" '
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-a,repo-b idea-nrm >/dev/null 2>&1; or exit 1
    cd "$WORK/home"
    worktree-merge --repos=repo-a,repo-b idea-nrm >/dev/null 2>&1; or exit 1
    worktree-stop --repos=repo-a,repo-b idea-nrm >/dev/null 2>&1; or exit 1
    not test -d "$__wt_worktree_home/idea-nrm/repo-a"; or exit 1
    not test -d "$__wt_worktree_home/idea-nrm/repo-b"; or exit 1
'

run_fish "non-interactive missing idea is a usage error" '
    cd "$__wt_github_home/repo-a"
    worktree-start >/dev/null 2>&1; and exit 1
    worktree-merge >/dev/null 2>&1; and exit 1
    worktree-stop >/dev/null 2>&1; and exit 1
    worktree-rm >/dev/null 2>&1; and exit 1
    worktree-venv >/dev/null 2>&1; and exit 1
'

echo "== description registry seeding =="

run_fish "description seeds a new registry row" '
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-a --description="seed description" idea-seed >/dev/null 2>&1; or exit 1
    string match -r "idea-seed.*seed description" (cat "$__wt_worktree_home/WORKTREES.md"); or exit 1
'

run_fish "conflicting description without --force errors" '
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-a --description="first" idea-seed2 >/dev/null 2>&1; or exit 1
    worktree-start --repos=repo-a --description="different" idea-seed2 >/dev/null 2>&1; and exit 1
    string match -r "idea-seed2.*first" (cat "$__wt_worktree_home/WORKTREES.md"); or exit 1
'

run_fish "--force overwrites an existing description" '
    cd "$__wt_github_home/repo-a"
    worktree-start --force --repos=repo-a --description="second" idea-seed2 >/dev/null 2>&1; or exit 1
    string match -r "idea-seed2.*second" (cat "$__wt_worktree_home/WORKTREES.md"); or exit 1
    not string match -q -r "idea-seed2.*first" "$__wt_worktree_home/WORKTREES.md"; or exit 1
'

run_fish "identical description is a no-op" '
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-a --description="second" idea-seed2 >/dev/null 2>&1; or exit 1
'

run_fish "pipe in description rejected before creating anything" '
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-a --description="bad|desc" idea-seed3 >/dev/null 2>&1; and exit 1
    not test -d "$__wt_worktree_home/idea-seed3/repo-a"; or exit 1
'

run_fish "old-schema registry auto-migrates and seeds" '
    mkdir -p "$WORK/oldschema"
    printf "# Worktrees\n\n| Idea | Branch | Repos | Plan file | Status |\n|---|---|---|---|---|\n| \`existing-idea\` | \`existing-idea\` | repo-a | a plan | active |\n" > "$WORK/oldschema/WORKTREES.md"
    set -l saved $__wt_worktree_home
    set -g __wt_worktree_home "$WORK/oldschema"
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-a --description="x" idea-old >/dev/null 2>&1; or exit 1
    string match -q "*| Idea | Branch | Repos | Description | Plan file | Status |*" (cat "$WORK/oldschema/WORKTREES.md"); or exit 1
    string match -q "*idea-old*x*active*" (cat "$WORK/oldschema/WORKTREES.md"); or exit 1
    string match -q "*existing-idea*active*" (cat "$WORK/oldschema/WORKTREES.md"); or exit 1
    set -g __wt_worktree_home $saved
'

run_fish "registry migration is idempotent and preserves existing rows" '
    mkdir -p "$WORK/migidem"
    printf "# Worktrees\n\n| Idea | Branch | Repos | Plan file | Status |\n|---|---|---|---|---|\n| \`existing-idea\` | \`existing-idea\` | repo-a | a plan | active |\n" > "$WORK/migidem/WORKTREES.md"
    set -l saved $__wt_worktree_home
    set -g __wt_worktree_home "$WORK/migidem"
    __wt_registry_migrate_description; or exit 1
    cp "$WORK/migidem/WORKTREES.md" "$WORK/migidem/before.md"
    __wt_registry_migrate_description; or exit 1
    cmp -s "$WORK/migidem/WORKTREES.md" "$WORK/migidem/before.md"; or exit 1
    string match -q "*existing-idea*repo-a*active*" (cat "$WORK/migidem/WORKTREES.md"); or exit 1
    set -g __wt_worktree_home $saved
'

run_fish "missing registry is created with header and row" '
    mkdir -p "$WORK/noreg"
    set -l saved $__wt_worktree_home
    set -g __wt_worktree_home "$WORK/noreg"
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-a --description="fresh idea" idea-fresh >/dev/null 2>&1; or exit 1
    test -f "$WORK/noreg/WORKTREES.md"; or exit 1
    string match -q "*| Description |*" (cat "$WORK/noreg/WORKTREES.md"); or exit 1
    string match -r "idea-fresh.*fresh idea" (cat "$WORK/noreg/WORKTREES.md"); or exit 1
    set -g __wt_worktree_home $saved
'

echo "== registry layer unit tests =="

run_fish "append refuses a duplicate row" '
    mkdir -p "$WORK/regunit"
    set -l saved $__wt_worktree_home
    set -g __wt_worktree_home "$WORK/regunit"
    __wt_registry_ensure_table; or exit 1
    __wt_registry_append_row idea-x "one" repo-a; or exit 1
    __wt_registry_append_row idea-x "two" repo-a 2>/dev/null; and exit 1
    test (count (__wt_registry_row_count idea-x)) = 1; or exit 1
    set -g __wt_worktree_home $saved
'

run_fish "rewrite updates only the description cell, preserves the rest" '
    mkdir -p "$WORK/regunit2"
    set -l saved $__wt_worktree_home
    set -g __wt_worktree_home "$WORK/regunit2"
    __wt_registry_append_row idea-x "one" repo-a repo-b; or exit 1
    __wt_registry_rewrite_row idea-x "two"; or exit 1
    set -l row (__wt_registry_row idea-x)
    string match -q "*two*" "$row"; or exit 1
    not string match -q "*one*" "$row"; or exit 1
    string match -q "*repo-a repo-b*" "$row"; or exit 1
    string match -q "*active*" "$row"; or exit 1
    set -g __wt_worktree_home $saved
'

run_fish "strict branch match ignores same-name occurrence in description" '
    mkdir -p "$WORK/regunit3"
    set -l saved $__wt_worktree_home
    set -g __wt_worktree_home "$WORK/regunit3"
    printf "# Worktrees\n\n| Idea | Branch | Repos | Description | Plan file | Status |\n|---|---|---|---|---|---|\n| `idea-x` | `idea-x` | repo-a | mentions `idea-other` |  | active |\n" > "$WORK/regunit3/WORKTREES.md"
    not __wt_registry_is_idea_row idea-other "| `idea-x` | `idea-x` | repo-a | mentions `idea-other` |  | active |"; or exit 1
    test -n (__wt_registry_row idea-x); or exit 1
    test -z (__wt_registry_row idea-other); or exit 1
    set -g __wt_worktree_home $saved
'

run_fish "write refuses duplicate rows (corruption guard)" '
    mkdir -p "$WORK/regunit4"
    set -l saved $__wt_worktree_home
    set -g __wt_worktree_home "$WORK/regunit4"
    printf "# Worktrees\n\n| Idea | Branch | Repos | Description | Plan file | Status |\n|---|---|---|---|---|---|\n| `idea-x` | `idea-x` | repo-a | one |  | active |\n| `idea-x` | `idea-x` | repo-a | two |  | active |\n" > "$WORK/regunit4/WORKTREES.md"
    __wt_registry_write idea-x "new" repo-a 2>/dev/null; and exit 1
    string match -q "*one*" (cat "$WORK/regunit4/WORKTREES.md"); or exit 1
    string match -q "*two*" (cat "$WORK/regunit4/WORKTREES.md"); or exit 1
    not string match -q "*new*" (cat "$WORK/regunit4/WORKTREES.md"); or exit 1
    set -g __wt_worktree_home $saved
'

run_fish "rewrite zero-match fails without touching the file" '
    mkdir -p "$WORK/regunit5"
    set -l saved $__wt_worktree_home
    set -g __wt_worktree_home "$WORK/regunit5"
    __wt_registry_ensure_table; or exit 1
    __wt_registry_rewrite_row ghost "x" 2>/dev/null; and exit 1
    test -f "$WORK/regunit5/WORKTREES.md"; or exit 1
    not string match -q "*ghost*" (cat "$WORK/regunit5/WORKTREES.md"); or exit 1
    set -g __wt_worktree_home $saved
'

run_fish "ensure_table leaves a non-empty registry untouched" '
    mkdir -p "$WORK/regunit6"
    set -l saved $__wt_worktree_home
    set -g __wt_worktree_home "$WORK/regunit6"
    echo "# custom title" > "$WORK/regunit6/WORKTREES.md"
    echo "keep me" >> "$WORK/regunit6/WORKTREES.md"
    __wt_registry_ensure_table; or exit 1
    string match -q "*custom title*" (cat "$WORK/regunit6/WORKTREES.md"); or exit 1
    string match -q "*keep me*" (cat "$WORK/regunit6/WORKTREES.md"); or exit 1
    not string match -q "| Idea |" (cat "$WORK/regunit6/WORKTREES.md"); or exit 1
    set -g __wt_worktree_home $saved
'

echo "== interactive prompting =="

run_fish_in "start prompts for idea, repos, description" '
    prompt-idea
    repo-a repo-b
    a described idea
' '
    cd "$__wt_github_home/repo-a"
    worktree-start >/dev/null 2>&1; or exit 1
    test (basename (pwd)) = repo-a; or exit 1
    test (basename (dirname (pwd))) = prompt-idea; or exit 1
    test -d "$__wt_worktree_home/prompt-idea/repo-b"; or exit 1
    string match -r "prompt-idea.*a described idea" (cat "$__wt_worktree_home/WORKTREES.md"); or exit 1
'

run_fish_in "repos prompt defaults to current repo" '
    prompt-default

    defaulted
' '
    cd "$__wt_github_home/repo-a"
    worktree-start >/dev/null 2>&1; or exit 1
    test -d "$__wt_worktree_home/prompt-default/repo-a"; or exit 1
    not test -d "$__wt_worktree_home/prompt-default/repo-b"; or exit 1
    string match -r "prompt-default.*defaulted" (cat "$__wt_worktree_home/WORKTREES.md"); or exit 1
'

run_fish_in "--save without --repos prompts and persists the set" '
    prompt-save
    repo-a repo-b
    saved idea
' '
    cd "$__wt_github_home/repo-a"
    worktree-start --save promptsave >/dev/null 2>&1; or exit 1
    set -l repos (__wt_read_group promptsave)
    contains -- repo-a $repos; or exit 1
    contains -- repo-b $repos; or exit 1
'

run_fish "seed idea-lc for lifecycle prompt tests" '
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-a,repo-b idea-lc >/dev/null 2>&1; or exit 1
'

run_fish_in "merge prompts for a missing idea (derive repos from worktrees)" '
    idea-lc
' '
    cd "$WORK/home"
    worktree-merge >/dev/null 2>&1; or exit 1
'

run_fish_in "rm prompts for a missing idea (derive repos from worktrees)" '
    idea-lc
    y
    y
' '
    cd "$WORK/home"
    worktree-rm >/dev/null 2>&1; or exit 1
    not test -d "$__wt_worktree_home/idea-lc/repo-a"; or exit 1
    not test -d "$__wt_worktree_home/idea-lc/repo-b"; or exit 1
    not git -C "$__wt_github_home/repo-a" branch --list idea-lc | string match -q "*idea-lc"; or exit 1
'

run_fish "seed idea-sp for stop prompt test" '
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-a idea-sp >/dev/null 2>&1; or exit 1
'

run_fish_in "stop prompts for a missing idea (derive repos from worktrees)" '
    idea-sp
' '
    cd "$WORK/home"
    worktree-stop >/dev/null 2>&1; or exit 1
    not test -d "$__wt_worktree_home/idea-sp/repo-a"; or exit 1
    git -C "$__wt_github_home/repo-a" branch --list idea-sp | string match -q "*idea-sp"; or exit 1
'

run_fish "seed idea-vp for venv prompt test" '
    cd "$__wt_github_home/repo-req"
    worktree-start --repos=repo-req idea-vp >/dev/null 2>&1; or exit 1
'

run_fish_in "venv prompts for idea and repos" '
    idea-vp
    repo-req
' '
    cd "$WORK/home"
    set -l out (worktree-venv 2>/dev/null)
    string match -q "*idea-vp" $out; or exit 1
'

run_fish "--help prints usage and exits 0 from any directory" '
    cd "$WORK/home"
    worktree-start --help >/dev/null 2>&1; or exit 1
    worktree-start -h >/dev/null 2>&1; or exit 1
    worktree-merge --help >/dev/null 2>&1; or exit 1
    worktree-stop --help >/dev/null 2>&1; or exit 1
    worktree-rm --help >/dev/null 2>&1; or exit 1
    worktree-venv --help >/dev/null 2>&1; or exit 1
'

echo "== environment fast-fail =="

# simulate an old git on PATH -> install must refuse before touching anything
OLDGIT="$WORK/oldgit"; mkdir -p "$OLDGIT"
printf '#!/bin/sh\necho "git version 2.30.0"\n' > "$OLDGIT/git"; chmod +x "$OLDGIT/git"
if PATH="$OLDGIT:$PATH" HOME="$WORK/home" bash "$ROOT/install.sh" >/dev/null 2>&1; then
    fail "install.sh accepts old git"
else
    ok "install.sh refuses old git"
fi

# simulate an old fish on PATH -> configure must refuse
OLDFISH="$WORK/oldfish"; mkdir -p "$OLDFISH"
printf '#!/bin/sh\necho "fish, version 3.2.1"\n' > "$OLDFISH/fish"; chmod +x "$OLDFISH/fish"
if PATH="$OLDFISH:$PATH" HOME="$WORK/home" bash "$ROOT/configure.sh" </dev/null >/dev/null 2>&1; then
    fail "configure.sh accepts old fish"
else
    ok "configure.sh refuses old fish"
fi

# simulate missing fish entirely -> install must refuse
# (minimal PATH /usr/bin:/bin has no fish on standard macOS; skip if a fish
#  somehow appears there)
if PATH="/usr/bin:/bin" command -v fish >/dev/null 2>&1; then
    echo "  skip  install.sh-without-fish (fish found on minimal PATH)"
elif PATH="/usr/bin:/bin" HOME="$WORK/home" bash "$ROOT/install.sh" >/dev/null 2>&1; then
    fail "install.sh runs without fish"
else
    ok "install.sh refuses when fish missing"
fi

# fish load-time guard: a too-old fish must stop sourcing the tool file.
# (Assert on the guard's emitted refusal message + nonzero source status; the
# conf.d autoload may still define functions, so function existence is not a
# reliable signal.)
if HOME="$WORK/home" fish -c "
    functions -e fish 2>/dev/null
    function fish
        echo 'fish, version 3.2.1'
    end
    set -l out (source \$HOME/.config/fish/conf.d/worktrees.fish 2>&1)
    set -l rc \$status
    string match -q '*too old*' \"\$out\"; or exit 1
    test \$rc -eq 1; or exit 1
    exit 0
" >/dev/null 2>&1; then
    ok "worktrees.fish refuses to load on old fish"
else
    fail "worktrees.fish loads on old fish"
fi

# symmetric: worktrees.fish load guard against old git
if HOME="$WORK/home" fish -c "
    functions -e git 2>/dev/null
    function git
        echo 'git version 2.30.0'
    end
    set -l out (source \$HOME/.config/fish/conf.d/worktrees.fish 2>&1)
    set -l rc \$status
    string match -q '*too old*' \"\$out\"; or exit 1
    test \$rc -eq 1; or exit 1
    exit 0
" >/dev/null 2>&1; then
    ok "worktrees.fish refuses to load on old git"
else
    fail "worktrees.fish loads on old git"
fi

# symmetric: configure.sh must refuse old git
OLDGIT2="$WORK/oldgit2"; mkdir -p "$OLDGIT2"
printf '#!/bin/sh\necho "git version 2.30.0"\n' > "$OLDGIT2/git"; chmod +x "$OLDGIT2/git"
if PATH="$OLDGIT2:$PATH" HOME="$WORK/home" bash "$ROOT/configure.sh" </dev/null >/dev/null 2>&1; then
    fail "configure.sh accepts old git"
else
    ok "configure.sh refuses old git"
fi

echo "== JS deps =="

run_fish "js manager picked from lockfile" '
    mkdir -p "$WORK/jstest"
    touch "$WORK/jstest/pnpm-lock.yaml"
    test (__wt_js_manager "$WORK/jstest") = pnpm; or exit 1
    rm "$WORK/jstest/pnpm-lock.yaml"
    touch "$WORK/jstest/yarn.lock"
    test (__wt_js_manager "$WORK/jstest") = yarn; or exit 1
    rm "$WORK/jstest/yarn.lock"
    touch "$WORK/jstest/bun.lockb"
    test (__wt_js_manager "$WORK/jstest") = bun; or exit 1
    rm "$WORK/jstest/bun.lockb"
    touch "$WORK/jstest/bun.lock"
    test (__wt_js_manager "$WORK/jstest") = bun; or exit 1
    rm "$WORK/jstest/bun.lock"
    touch "$WORK/jstest/package-lock.json"
    test (__wt_js_manager "$WORK/jstest") = npm; or exit 1
'

run_fish "node installs in every repo with package.json, manager per lockfile" '
    set -gx PATH "$WT_NODEBIN:$PATH"
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-js,repo-js-bare,repo-pnpm,repo-a idea-js >/dev/null 2>&1; or exit 1
    test -d "$__wt_worktree_home/idea-js/repo-js/node_modules"; or exit 1
    test -d "$__wt_worktree_home/idea-js/repo-js-bare/node_modules"; or exit 1
    test -d "$__wt_worktree_home/idea-js/repo-pnpm/node_modules"; or exit 1
    not test -d "$__wt_worktree_home/idea-js/repo-a/node_modules"; or exit 1
    string match -q "*npm ci*" (cat "$WT_NODEBIN/npm-calls.log" 2>/dev/null); or exit 1
    string match -qr '^npm install$' (cat "$WT_NODEBIN/npm-calls.log" 2>/dev/null); or exit 1
    string match -q "*pnpm install --frozen-lockfile*" (cat "$WT_NODEBIN/npm-calls.log" 2>/dev/null); or exit 1
'

run_fish "lockfile manager missing falls back to npm" '
    mkdir -p "$WORK/npmonly"
    ln -sf "$WT_NODEBIN/npm" "$WORK/npmonly/npm"
    rm -f "$WT_NODEBIN/npm-calls.log"
    set -gx PATH "$WORK/npmonly:$WT_TESTBIN:/usr/bin:/bin:/usr/sbin"
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-pnpm,repo-a idea-jsfb >/dev/null 2>&1; or exit 1
    test -d "$__wt_worktree_home/idea-jsfb/repo-pnpm/node_modules"; or exit 1
    string match -qr '^npm install$' (cat "$WT_NODEBIN/npm-calls.log" 2>/dev/null); or exit 1
'

run_fish "no JS manager on PATH skips install with warning" '
    set -gx PATH "$WT_TESTBIN:/usr/bin:/bin:/usr/sbin"
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-js,repo-a idea-jsnm >/dev/null 2>&1; or exit 1
    not test -d "$__wt_worktree_home/idea-jsnm/repo-js/node_modules"; or exit 1
'

run_fish "node install skipped when node_modules already present" '
    set -gx PATH "$WT_NODEBIN:$PATH"
    cd "$__wt_github_home/repo-a"
    set -l before (wc -l < "$WT_NODEBIN/npm-calls.log" 2>/dev/null; or echo 0)
    worktree-start --repos=repo-js,repo-js-bare,repo-pnpm,repo-a idea-js >/dev/null 2>&1; or exit 1
    set -l after (wc -l < "$WT_NODEBIN/npm-calls.log" 2>/dev/null; or echo 0)
    test "$before" = "$after"; or exit 1
'

echo
echo "== opencode model-routing install =="

# plugin syntax gate (skip cleanly if node is absent)
if command -v node >/dev/null 2>&1; then
    if node --check "$ROOT/opencode/model-routing-alarm.js" >/dev/null 2>&1; then
        ok "model-routing-alarm.js parses"
    else
        fail "model-routing-alarm.js parse error"
    fi
else
    echo "  skip  node --check (node not on PATH)"
fi

# merge-instructions.py against a temp config
OCFG="$WORK/ocfg"; mkdir -p "$OCFG"
printf '{"$schema":"https://opencode.ai/config.json","username":"t"}\n' > "$OCFG/opencode.json"
if python3 "$ROOT/opencode/merge-instructions.py" "$OCFG/opencode.json" "$ROOT/opencode/model-routing.md" >/dev/null 2>&1; then
    ok "merge-instructions.py runs on an existing config"
else
    fail "merge-instructions.py failed on an existing config"
fi
if grep -q '"instructions"' "$OCFG/opencode.json" && grep -q '"username"' "$OCFG/opencode.json"; then
    ok "merge adds instructions, preserves existing keys"
else
    fail "merge did not add instructions or dropped existing keys"
fi
if [ "$(ls "$OCFG"/opencode.json.bak-* 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
    ok "merge writes exactly one backup on first change"
else
    fail "merge backup count != 1 after first change"
fi

# re-run: no-op, no second backup, byte-identical file
python3 "$ROOT/opencode/merge-instructions.py" "$OCFG/opencode.json" "$ROOT/opencode/model-routing.md" >/dev/null 2>&1
if [ "$(ls "$OCFG"/opencode.json.bak-* 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
    ok "merge re-run is a no-op (no second backup)"
else
    fail "merge re-run created a second backup"
fi
# merge output must be valid JSON and stable under re-serialization
if python3 -c "import json,sys; json.load(open('$OCFG/opencode.json'))" >/dev/null 2>&1; then
    ok "merge output is valid JSON"
else
    fail "merge output is not valid JSON"
fi
if cmp -s "$OCFG/opencode.json" <(python3 -c "import json;print(json.dumps(json.load(open('$OCFG/opencode.json')),indent=2,ensure_ascii=False)+'\n',end='')"); then
    ok "merge output is stable under re-serialization"
else
    fail "merge output is not stable under re-serialization"
fi

# absent config -> minimal config created, no backup needed
rm -f "$OCFG/absent.json"
if python3 "$ROOT/opencode/merge-instructions.py" "$OCFG/absent.json" "$ROOT/opencode/model-routing.md" >/dev/null 2>&1 \
   && grep -q '"$schema"' "$OCFG/absent.json" && grep -q '"instructions"' "$OCFG/absent.json"; then
    ok "merge creates a minimal config when the file is absent"
else
    fail "merge did not create a minimal absent config"
fi

# invalid JSON -> exit nonzero, file left untouched
printf '{not valid json\n' > "$OCFG/bad.json"
if python3 "$ROOT/opencode/merge-instructions.py" "$OCFG/bad.json" "$ROOT/opencode/model-routing.md" >/dev/null 2>&1; then
    fail "merge accepts invalid JSON"
else
    ok "merge refuses invalid JSON"
fi
if grep -q '{not valid json' "$OCFG/bad.json"; then
    ok "merge leaves an invalid file untouched"
else
    fail "merge modified an invalid file"
fi

# configure --defaults: non-interactive, writes config + seeds groups
if HOME="$WORK/home2" bash "$ROOT/configure.sh" --defaults </dev/null >/dev/null 2>&1; then
    ok "configure.sh --defaults runs non-interactively"
else
    fail "configure.sh --defaults failed"
fi
if test -f "$WORK/home2/.config/fish/conf.d/worktrees-config.fish" \
   && test -f "$WORK/home2/git-worktrees/WORKTREE-GROUPS"; then
    ok "configure --defaults writes config and seeds WORKTREE-GROUPS"
else
    fail "configure --defaults did not write config/seed groups"
fi

# zero-state install: self-provisions config, symlinks plugin, merges instructions
mkdir -p "$WORK/home3"
if HOME="$WORK/home3" bash "$ROOT/install.sh" </dev/null >/dev/null 2>&1; then
    ok "install.sh succeeds from zero state"
else
    fail "install.sh failed from zero state"
fi
if test -f "$WORK/home3/.config/fish/conf.d/worktrees-config.fish"; then
    ok "install.sh self-provisions the fish config"
else
    fail "install.sh did not self-provision the fish config"
fi
if test -L "$WORK/home3/.config/opencode/plugin/model-routing-alarm.js"; then
    ok "install.sh symlinks the alarm plugin"
else
    fail "install.sh did not symlink the alarm plugin"
fi
if grep -q '"instructions"' "$WORK/home3/.config/opencode/opencode.json"; then
    ok "install.sh merges the routing contract into opencode.json"
else
    fail "install.sh did not merge instructions into opencode.json"
fi

# re-run install: config preserved (marker survives), no new backup
# (a fresh absent config is created with backup=False, so 0 backups total)
echo '# marker' >> "$WORK/home3/.config/fish/conf.d/worktrees-config.fish"
if HOME="$WORK/home3" bash "$ROOT/install.sh" </dev/null >/dev/null 2>&1; then
    ok "install.sh re-run succeeds"
else
    fail "install.sh re-run failed"
fi
if grep -q '# marker' "$WORK/home3/.config/fish/conf.d/worktrees-config.fish"; then
    ok "install.sh re-run leaves an existing config untouched"
else
    fail "install.sh re-run clobbered an existing config"
fi
if [ "$(ls "$WORK/home3/.config/opencode"/opencode.json.bak-* 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
    ok "install.sh re-run creates no opencode.json backup (no-op merge)"
else
    fail "install.sh re-run created an unexpected backup"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
