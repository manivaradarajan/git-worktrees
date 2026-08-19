#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$REPO/config"

ln -sf "$CONFIG/opencode.json" "$HOME/.config/opencode/opencode.json"
ln -sf "$CONFIG/agents/style-reviewer.md" "$HOME/.config/opencode/agents/style-reviewer.md"
ln -sf "$CONFIG/agents/design-reviewer.md" "$HOME/.config/opencode/agents/design-reviewer.md"
ln -sf "$CONFIG/CLAUDE.md" "$HOME/.claude/CLAUDE.md"

echo "Symlinks updated:"
for target in \
  "$HOME/.config/opencode/opencode.json" \
  "$HOME/.config/opencode/agents/style-reviewer.md" \
  "$HOME/.config/opencode/agents/design-reviewer.md" \
  "$HOME/.claude/CLAUDE.md"; do
  printf "  %s -> %s\n" "$target" "$(readlink "$target")"
done
