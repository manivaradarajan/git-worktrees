#!/usr/bin/env bash
# install.sh — install the worktrees tooling into the local environment.
#
# Idempotent: safe to re-run. Symlinks worktrees.fish into the fish conf.d
# directory (so `git pull` in this repo updates the tooling in place) and sets
# the `git plan` alias. Does NOT configure homes or groups — run ./configure.sh
# first.
#
# Usage:   ./install.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- 0. environment fast-fail ------------------------------------------------------
# Refuse to install on unsupported fish/git so the failure is clear and
# immediate, not a cryptic first-use error later.
# NOTE: `require_version` is duplicated in configure.sh — keep the two in sync.

require_version() {
    # $1 = tool name, $2 = current version (X.Y[.Z]), $3 = required (X.Y[.Z]).
    # Compares major/minor/patch (defaulted to 0) — mirrors worktrees.fish's
    # __wt_version_ge.
    local name="$1" cur="$2" req="$3"
    IFS=. read -r -a c <<<"$cur"; IFS=. read -r -a r <<<"$req"
    while (( ${#c[@]} < 3 )); do c+=(0); done
    while (( ${#r[@]} < 3 )); do r+=(0); done
    if (( c[0]*1000000 + c[1]*1000 + c[2] >= r[0]*1000000 + r[1]*1000 + r[2] )); then
        return 0
    fi
    echo "install.sh: $name $cur is too old (need >= $req). upgrade and re-run." >&2
    return 1
}

if ! command -v fish >/dev/null 2>&1; then
    echo "install.sh: fish is not installed (required for worktrees.fish). install fish first." >&2
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    echo "install.sh: git is not installed (required). install git first." >&2
    exit 1
fi

FISH_VER="$(fish --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p')"
GIT_VER="$(git --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p')"
test -n "$FISH_VER" || { echo "install.sh: could not determine fish version" >&2; exit 1; }
test -n "$GIT_VER"  || { echo "install.sh: could not determine git version" >&2; exit 1; }

require_version fish "$FISH_VER" 3.3 || exit 1
require_version git  "$GIT_VER"  2.31 || exit 1
echo "environment ok: fish $FISH_VER, git $GIT_VER"

# -- 1. symlink worktrees.fish into fish conf.d -----------------------------------

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d"
mkdir -p "$CONF_DIR"
ln -sf "$REPO_DIR/worktrees.fish" "$CONF_DIR/worktrees.fish"
echo "symlinked $CONF_DIR/worktrees.fish -> $REPO_DIR/worktrees.fish"

# -- 2. set the git plan alias ------------------------------------------------------
# Reads the current worktree's row from main:WORKTREES.md. The branch column is
# backtick-delimited; the stored config value must contain `\`` (backslash +
# backtick) so POSIX sh renders a LITERAL backtick inside double quotes. The
# single-quoted string argument to printf preserves the backslashes verbatim.
# Stored value (for reference):
#   !git show main:WORKTREES.md 2>/dev/null | grep -F "| \`$(git branch --show-current)\` |" || { echo "No WORKTREES.md row for branch: $(git branch --show-current) — add one on main."; git worktree list; }

PLAN_ALIAS="$(printf '%s' '!git show main:WORKTREES.md 2>/dev/null | grep -F "| \`$(git branch --show-current)\` |" || { echo "No WORKTREES.md row for branch: $(git branch --show-current) — add one on main."; git worktree list; }')"

git config --global alias.plan "$PLAN_ALIAS"

echo "set git alias: plan"

# -- 3. reload hint -----------------------------------------------------------------

echo
echo "Reload fish, or in the current shell run:"
echo "  source ~/.config/fish/conf.d/worktrees.fish"
echo "Then verify with: functions -q worktree-start; and echo ok"
