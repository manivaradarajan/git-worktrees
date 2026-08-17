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
# pip fallback, python3 fast-fail) / environment fast-fail guards. All installs
# are offline (manifests are dependency-free).
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

# python repos for shared-venv coverage — manifests are dependency-free so all
# installs are offline and instant
for r in repo-req repo-req2 repo-py; do
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
for r in repo-req repo-req2 repo-py; do
    git -C "$GITHUB_HOME/$r" add -A
    git -C "$GITHUB_HOME/$r" commit -qm python-manifests
done

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

| Idea | Branch | Repos | Plan file | Status |
|---|---|---|---|---|
| \`idea-one\` | \`idea-one\` | repo-a | Test idea one | active |
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
    cd "$__wt_worktree_home/repo-req/idea-python"
    test -n "$VIRTUAL_ENV"; or exit 1
    mkdir -p "$__wt_worktree_home/repo-req/idea-python/sub"
    cd "$__wt_worktree_home/repo-req/idea-python/sub"
    test -n "$VIRTUAL_ENV"; or exit 1
    cd "$__wt_github_home/repo-req"
    test -z "$VIRTUAL_ENV"; or exit 1
    worktree-start --repos=repo-req idea-python2 >/dev/null 2>&1; or exit 1
    cd "$__wt_worktree_home/repo-req/idea-python"
    test -n "$VIRTUAL_ENV"; or exit 1
    cd "$__wt_worktree_home/repo-req/idea-python2"
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
    not test -d "$__wt_worktree_home/repo-req/idea-nopython"; or exit 1
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
    test -d "$__wt_worktree_home/repo-js/idea-js/node_modules"; or exit 1
    test -d "$__wt_worktree_home/repo-js-bare/idea-js/node_modules"; or exit 1
    test -d "$__wt_worktree_home/repo-pnpm/idea-js/node_modules"; or exit 1
    not test -d "$__wt_worktree_home/repo-a/idea-js/node_modules"; or exit 1
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
    test -d "$__wt_worktree_home/repo-pnpm/idea-jsfb/node_modules"; or exit 1
    string match -qr '^npm install$' (cat "$WT_NODEBIN/npm-calls.log" 2>/dev/null); or exit 1
'

run_fish "no JS manager on PATH skips install with warning" '
    set -gx PATH "$WT_TESTBIN:/usr/bin:/bin:/usr/sbin"
    cd "$__wt_github_home/repo-a"
    worktree-start --repos=repo-js,repo-a idea-jsnm >/dev/null 2>&1; or exit 1
    not test -d "$__wt_worktree_home/repo-js/idea-jsnm/node_modules"; or exit 1
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
