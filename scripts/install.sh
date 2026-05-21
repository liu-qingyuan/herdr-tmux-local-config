#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stamp="$(date +%Y%m%d%H%M%S)"

backup_copy() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    cp -a "$dst" "${dst}.bak-herdr-local-config-${stamp}"
  fi
  cp "$src" "$dst"
}

backup_copy "$repo_root/dotfiles/herdr/config.toml" "$HOME/.config/herdr/config.toml"
backup_copy "$repo_root/dotfiles/herdr/scripts/focus-next-tab.py" "$HOME/.config/herdr/scripts/focus-next-tab.py"
backup_copy "$repo_root/dotfiles/codex/herdr-agent-state.sh" "$HOME/.codex/herdr-agent-state.sh"
chmod +x "$HOME/.config/herdr/scripts/focus-next-tab.py" "$HOME/.codex/herdr-agent-state.sh"

cat <<'MSG'
Installed Herdr local config files.

Manual follow-up:
1. Merge dotfiles/codex/hooks.herdr.json into ~/.codex/hooks.json if missing.
2. Source shell/omx-herdr-wrapper.zsh from ~/.zshrc, or merge the wrapper manually.
3. Restart/reload Herdr and start a fresh Codex/OMX session for HERDR_* propagation.
MSG
