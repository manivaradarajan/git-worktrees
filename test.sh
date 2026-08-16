#!/usr/bin/env bash
# test.sh — automated lifecycle test for the worktrees tooling.
#
# Builds throwaway repos in a temp dir, runs configure+install against a temp
# HOME, then exercises the fish functions and git plan against the sandbox.
# Fails (nonzero) if any assertion fails. Safe to run anywhere; cleans up.
#
# Usage:   ./test.sh
# no `-e` on purpose: run_fish + ok/fail manage status explicitly; `-e` would
# abort mid-harness on the first expected failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d /tmp/wt-test.XXXXXX)" || { echo "mktemp failed" >&2; exit 1; }
GITHUB_HOME="$WORK/github"
WT_HOME="$WORK/wt"

trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# run_fish <label> <script> — run fish with the tooling loaded and a temp HOME.
# The trailing `exit 0` makes the overall rc deterministic: any mid-script
# `exit 1` still aborts, but an assertion that correctly fails (e.g. a command
# that must fail) no longer leaks its nonzero status into the final rc.
run_fish() {
    local label="$1" script="$2"
    local out
    out="$(HOME="$WORK/home" fish -c "
        set -gx XDG_CONFIG_HOME \"\$HOME/.config\"
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

# registry on repo-a main so `git plan` has a row to match
cat > "$GITHUB_HOME/repo-a/WORKTREES.md" <<EOF
# Worktrees

| Worktree dir | Branch | Idea | Status |
|---|---|---|---|
| \`$WT_HOME/repo-a/idea-one\` | \`idea-one\` | Test idea one | active |
EOF
git -C "$GITHUB_HOME/repo-a" add WORKTREES.md
git -C "$GITHUB_HOME/repo-a" commit -qm registry

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
    test -d "$__wt_worktree_home/repo-a/idea-one"; or exit 1
'

run_fish "start is idempotent (re-run ok)" '
    cd "$__wt_github_home/repo-a"
    worktree-start idea-one >/dev/null 2>&1; or exit 1
'

run_fish "multi-repo start creates both worktrees" '
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-a,repo-b idea-two >/dev/null 2>&1; or exit 1
    test -d "$__wt_worktree_home/repo-b/idea-two"; or exit 1
'

run_fish "missing repo preflights (creates nothing)" '
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-a,ghost idea-three >/dev/null 2>&1; and exit 1
    not test -d "$__wt_worktree_home/repo-a/idea-three"; or exit 1
'

run_fish "invalid idea rejected" '
    cd "$__wt_github_home/repo-a"
    worktree-start "foo/bar" >/dev/null 2>&1; and exit 1
'

run_fish "existing bogus destination rejected" '
    cd "$__wt_github_home/repo-a"
    mkdir -p "$__wt_worktree_home/repo-a/bogus"
    worktree-start bogus >/dev/null 2>&1; and exit 1
'

run_fish "go enters this repo worktree" '
    cd "$__wt_github_home/repo-a"
    worktree-go idea-one >/dev/null 2>&1; or exit 1
    test (basename (pwd)) = idea-one; or exit 1
'

run_fish "git plan matches registry row" '
    cd "$__wt_worktree_home/repo-a/idea-one"
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
    git -C "$__wt_worktree_home/repo-a/idea-one" commit -q --allow-empty -m wip
    worktree-merge idea-one >/dev/null 2>&1; or exit 1
    git merge-base --is-ancestor idea-one main; or exit 1
'

run_fish "stop removes dir, keeps branch" '
    cd "$__wt_github_home/repo-a"
    worktree-stop idea-one >/dev/null 2>&1; or exit 1
    not test -d "$__wt_worktree_home/repo-a/idea-one"; or exit 1
    git branch --list idea-one | string match -q "*idea-one"; or exit 1
'

run_fish "stop refuses dirty worktree without --force" '
    cd "$__wt_github_home/repo-a"
    worktree-start idea-one >/dev/null 2>&1
    echo wip >> "$__wt_worktree_home/repo-a/idea-one/base.txt"
    worktree-stop idea-one >/dev/null 2>&1; and exit 1
    worktree-stop --force idea-one >/dev/null 2>&1; or exit 1
    not test -d "$__wt_worktree_home/repo-a/idea-one"; or exit 1
'

run_fish "resume re-attaches parked branch" '
    cd "$__wt_github_home/repo-a"
    worktree-start idea-one >/dev/null 2>&1; or exit 1
    test (git branch --show-current) = idea-one; or exit 1
'

run_fish "rm removes worktree and merged branch" '
    cd "$__wt_github_home/repo-a"
    worktree-rm idea-one </dev/null >/dev/null 2>&1; or exit 1
    not test -d "$__wt_worktree_home/repo-a/idea-one"; or exit 1
    not git branch --list idea-one | string match -q "*idea-one"; or exit 1
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

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
