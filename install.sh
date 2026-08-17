#!/usr/bin/env bash
# install.sh — install the worktrees tooling into the local environment.
#
# Idempotent: safe to re-run. Self-provisions on first run: if the fish config
# override does not exist it runs ./configure.sh --defaults (default homes, no
# prompts), so zero-state setup is a single command. Then symlinks worktrees.fish
# into the fish conf.d directory (so `git pull` in this repo updates the tooling
# in place), sets the `git plan` alias, symlinks the opencode model-routing alarm
# plugin, and merges its routing contract into opencode.json (atomic write,
# timestamped backup, no-op on re-run).
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

# -- 0b. optional-prereq warnings (never fatal) -----------------------------------
# python3 is needed to merge the model-routing instructions into opencode.json;
# node is needed to run the model-routing alarm plugin. The worktrees core only
# needs fish+git, so their absence is a warning, not a hard failure.

if ! command -v python3 >/dev/null 2>&1; then
    echo "install.sh: python3 not found — skipping the opencode.json merge; add" >&2
    echo "  \"instructions\": [\"$REPO_DIR/opencode/model-routing.md\"]" >&2
    echo "  to ~/.config/opencode/opencode.json manually." >&2
fi
if ! command -v node >/dev/null 2>&1; then
    echo "install.sh: node not found — the model-routing alarm plugin will not" >&2
    echo "  run until opencode is restarted with node available." >&2
fi

# -- 1. self-provision the fish config if absent ----------------------------------
# One-shot `./install.sh` from zero state: configure --defaults writes the config
# override (default homes) and seeds WORKTREE-GROUPS, but ONLY when the config
# file does not already exist. If it exists it is never touched, so custom homes
# are preserved on re-runs. Re-assert afterwards so a failed configure cannot
# silently continue.

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d"
CONF_FILE="$CONF_DIR/worktrees-config.fish"
if [[ ! -f "$CONF_FILE" ]]; then
    echo "no $CONF_FILE — running ./configure.sh --defaults"
    bash "$REPO_DIR/configure.sh" --defaults || exit 1
fi
if [[ ! -f "$CONF_FILE" ]]; then
    echo "install.sh: configure.sh --defaults did not create $CONF_FILE" >&2
    exit 1
fi

# -- 2. symlink worktrees.fish into fish conf.d -----------------------------------

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d"
mkdir -p "$CONF_DIR"
ln -sf "$REPO_DIR/worktrees.fish" "$CONF_DIR/worktrees.fish"
echo "symlinked $CONF_DIR/worktrees.fish -> $REPO_DIR/worktrees.fish"

# -- 3. set the git plan alias ------------------------------------------------------
# Reads the current branch's row from the GLOBAL idea registry
# ($__wt_worktree_home/WORKTREES.md, alongside WORKTREE-GROUPS) — not a
# per-repo committed file. The branch column is backtick-delimited; the stored
# config value must contain `\`` (backslash + backtick) so POSIX sh renders a
# LITERAL backtick inside double quotes. The single-quoted argument to printf
# preserves the backslashes verbatim; the path to WORKTREES.md (marked $WT_HOME
# below) is interpolated at install time from the worktrees-config.fish written
# by configure.sh, while `$(...)` runs at alias-invocation time.
# Stored value (for reference):
#   !grep -F "| \`$(git branch --show-current)\` |" "$WT_HOME/WORKTREES.md" 2>/dev/null || { echo "No WORKTREES.md row for branch: $(git branch --show-current) — add one in $WT_HOME/WORKTREES.md."; git worktree list; }

CONF_FILE="$CONF_DIR/worktrees-config.fish"
# Ask fish to evaluate the config so hand-edited quoting/formatting can't break
# the parse (sed on the exact line would silently fall back).
WT_HOME=""
if [[ -f "$CONF_FILE" ]]; then
    WT_HOME="$(fish -c "source '$CONF_FILE' >/dev/null 2>&1; and echo \"\$__wt_worktree_home\"" 2>/dev/null)"
fi
test -n "$WT_HOME" || WT_HOME="$HOME/git-worktrees"

PLAN_ALIAS="$(printf '%s' "!grep -F \"| \\\`\$(git branch --show-current)\\\` |\" \"$WT_HOME/WORKTREES.md\" 2>/dev/null || { echo \"No WORKTREES.md row for branch: \$(git branch --show-current) — add one in $WT_HOME/WORKTREES.md.\"; git worktree list; }")"

git config --global alias.plan "$PLAN_ALIAS"

echo "set git alias: plan (reads $WT_HOME/WORKTREES.md)"

# -- 4. opencode model-routing install ---------------------------------------------
# Symlink the alarm plugin into opencode's plugin dir (auto-discovered) and
# register the routing contract in the global config. Both are idempotent and
# safe to re-run; `git pull` in this repo updates the symlinked plugin in place.
# The config merge is atomic with a timestamped backup — see
# opencode/merge-instructions.py.

OCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
mkdir -p "$OCODE_DIR/plugin"
ln -sf "$REPO_DIR/opencode/model-routing-alarm.js" "$OCODE_DIR/plugin/model-routing-alarm.js"
echo "symlinked $OCODE_DIR/plugin/model-routing-alarm.js -> $REPO_DIR/opencode/model-routing-alarm.js"

if command -v python3 >/dev/null 2>&1; then
    if ! python3 "$REPO_DIR/opencode/merge-instructions.py" \
        "$OCODE_DIR/opencode.json" "$REPO_DIR/opencode/model-routing.md"; then
        echo "install.sh: warning: failed to merge instructions into $OCODE_DIR/opencode.json" >&2
    fi
else
    echo "install.sh: python3 not found — add this to opencode.json manually:" >&2
    echo "  \"instructions\": [\"$REPO_DIR/opencode/model-routing.md\"]" >&2
fi

# -- 5. reload hint -----------------------------------------------------------------

echo
echo "Reload fish, or in the current shell run:"
echo "  source ~/.config/fish/conf.d/worktrees.fish"
echo "Then verify with: functions -q worktree-start; and echo ok"
echo
echo "opencode: quit and restart opencode for the model-routing plugin and"
echo "  instructions to load (config is read at startup, not hot-reloaded)."
