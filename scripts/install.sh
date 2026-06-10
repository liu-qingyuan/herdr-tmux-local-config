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

install_if_present() {
  local src="$1"
  local dst="$2"
  if [ -e "$src" ]; then
    backup_copy "$src" "$dst"
  fi
}

backup_copy "$repo_root/dotfiles/herdr/config.toml" "$HOME/.config/herdr/config.toml"
install_if_present "$repo_root/dotfiles/herdr/scripts/focus-next-tab.py" "$HOME/.config/herdr/scripts/focus-next-tab.py"
backup_copy "$repo_root/dotfiles/codex/herdr-agent-state.sh" "$HOME/.codex/herdr-agent-state.sh"
backup_copy "$repo_root/dotfiles/codex/herdr-omx-state.sh" "$HOME/.codex/herdr-omx-state.sh"
backup_copy "$repo_root/dotfiles/local/bin/herdr-omx-reconcile" "$HOME/.local/bin/herdr-omx-reconcile"
backup_copy "$repo_root/dotfiles/local/bin/herdr-omx-reconcile-watch" "$HOME/.local/bin/herdr-omx-reconcile-watch"
install_if_present "$repo_root/dotfiles/systemd/user/herdr-omx-reconcile-watch.service" "$HOME/.config/systemd/user/herdr-omx-reconcile-watch.service"
chmod +x "$HOME/.codex/herdr-agent-state.sh" "$HOME/.codex/herdr-omx-state.sh" "$HOME/.local/bin/herdr-omx-reconcile" "$HOME/.local/bin/herdr-omx-reconcile-watch"
if command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
  systemctl --user daemon-reload || true
  systemctl --user enable --now herdr-omx-reconcile-watch.service || true
fi
if ! pgrep -u "$(id -u)" -f '[h]erdr-omx-reconcile-watch' >/dev/null 2>&1; then
  HERDR_OMX_WATCH_INTERVAL=1 nohup "$HOME/.local/bin/herdr-omx-reconcile-watch" >/tmp/herdr-omx-reconcile-watch.log 2>&1 &
fi

cat <<'MSG'
Installed Herdr local config files.

Manual follow-up:
1. Merge dotfiles/codex/hooks.herdr.json into ~/.codex/hooks.json if missing.
2. Add a command hook entry for ~/.codex/herdr-omx-state.sh to OMX/Codex homes that should report semantic OMX state.
3. Source shell/omx-herdr-wrapper.zsh from ~/.zshrc, or merge the wrapper manually.
4. Restart/reload Herdr and start a fresh Codex/OMX session for HERDR_* propagation.
MSG
