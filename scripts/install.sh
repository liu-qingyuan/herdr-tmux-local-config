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

merge_codex_hooks() {
  local fragment="$repo_root/dotfiles/codex/hooks.herdr.json"
  local target="$HOME/.codex/hooks.json"
  mkdir -p "$(dirname "$target")"
  if [ ! -e "$target" ]; then
    printf '{\n  "hooks": {}\n}\n' >"$target"
  fi
  cp -a "$target" "${target}.bak-herdr-local-config-${stamp}"
  python3 - "$fragment" "$target" <<'PY'
import json
import re
import sys
from pathlib import Path

fragment_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
fragment = json.loads(fragment_path.read_text())
target = json.loads(target_path.read_text())
target.setdefault("hooks", {})


def normalize_command(command: str) -> str:
    command = command.replace("'", '"')
    command = command.replace(str(Path.home()), "$HOME")
    command = re.sub(r"\s+", " ", command.strip())
    return command


def has_equivalent(groups, command):
    wanted = normalize_command(command)
    for group in groups:
        if not isinstance(group, dict):
            continue
        for hook in group.get("hooks", []):
            if isinstance(hook, dict) and normalize_command(str(hook.get("command", ""))) == wanted:
                return True
    return False

for event, groups in fragment.get("hooks", {}).items():
    dest = target["hooks"].setdefault(event, [])
    for group in groups:
        hooks = group.get("hooks", []) if isinstance(group, dict) else []
        if not hooks:
            continue
        command = str(hooks[0].get("command", ""))
        if command and not has_equivalent(dest, command):
            dest.append(group)

target_path.write_text(json.dumps(target, ensure_ascii=False, indent=2) + "\n")
PY
}

install_zsh_wrapper_block() {
  local zshrc="$HOME/.zshrc"
  local wrapper="$repo_root/shell/omx-herdr-wrapper.zsh"
  [ -e "$wrapper" ] || return 0
  touch "$zshrc"
  cp -a "$zshrc" "${zshrc}.bak-herdr-local-config-${stamp}"
  python3 - "$wrapper" "$zshrc" <<'PY'
import sys
from pathlib import Path

wrapper_path = Path(sys.argv[1])
zshrc_path = Path(sys.argv[2])
wrapper = wrapper_path.read_text().rstrip() + "\n"
text = zshrc_path.read_text()
start = "# >>> herdr-local-config omx wrapper >>>\n"
end = "# <<< herdr-local-config omx wrapper <<<\n"
block = start + wrapper + end
if start in text and end in text:
    prefix = text.split(start, 1)[0]
    suffix = text.split(start, 1)[1].split(end, 1)[1]
    new_text = prefix + block + suffix
else:
    marker = "# Default OMX launcher: prefer the stable inside-tmux path."
    if marker in text and "\nsymphony() {" in text:
        prefix = text.split(marker, 1)[0]
        suffix = "symphony() {" + text.split("\nsymphony() {", 1)[1]
        new_text = prefix.rstrip() + "\n\n" + block + "\n" + suffix
    else:
        new_text = text.rstrip() + "\n\n" + block
zshrc_path.write_text(new_text)
PY
}

backup_copy "$repo_root/dotfiles/herdr/config.toml" "$HOME/.config/herdr/config.toml"
install_if_present "$repo_root/dotfiles/herdr/scripts/focus-next-tab.py" "$HOME/.config/herdr/scripts/focus-next-tab.py"
backup_copy "$repo_root/dotfiles/codex/herdr_pane_binding.py" "$HOME/.codex/herdr_pane_binding.py"
backup_copy "$repo_root/dotfiles/codex/herdr-agent-state.sh" "$HOME/.codex/herdr-agent-state.sh"
backup_copy "$repo_root/dotfiles/codex/herdr-omx-state.sh" "$HOME/.codex/herdr-omx-state.sh"
backup_copy "$repo_root/dotfiles/local/bin/herdr-omx-reconcile" "$HOME/.local/bin/herdr-omx-reconcile"
backup_copy "$repo_root/dotfiles/local/bin/herdr-omx-reconcile-watch" "$HOME/.local/bin/herdr-omx-reconcile-watch"
install_if_present "$repo_root/dotfiles/systemd/user/herdr-omx-reconcile-watch.service" "$HOME/.config/systemd/user/herdr-omx-reconcile-watch.service"
chmod +x "$HOME/.codex/herdr-agent-state.sh" "$HOME/.codex/herdr-omx-state.sh" "$HOME/.local/bin/herdr-omx-reconcile" "$HOME/.local/bin/herdr-omx-reconcile-watch"
[ ! -e "$HOME/.config/herdr/scripts/focus-next-tab.py" ] || chmod +x "$HOME/.config/herdr/scripts/focus-next-tab.py"

merge_codex_hooks
install_zsh_wrapper_block

if command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
  systemctl --user daemon-reload || true
  systemctl --user enable --now herdr-omx-reconcile-watch.service || true
fi
if ! pgrep -u "$(id -u)" -f '[h]erdr-omx-reconcile-watch' >/dev/null 2>&1; then
  HERDR_OMX_WATCH_INTERVAL=1 nohup "$HOME/.local/bin/herdr-omx-reconcile-watch" >/tmp/herdr-omx-reconcile-watch.log 2>&1 &
fi

cat <<'MSG'
Installed Herdr local config files.

Applied automatically:
- copied Herdr/Codex/OMX bridge scripts
- merged Herdr hook entries into ~/.codex/hooks.json without removing existing hooks
- installed a managed omx/omx-max wrapper block in ~/.zshrc
- started herdr-omx-reconcile-watch when no watcher was running

Restart/reload Herdr or open a fresh tab if shell startup files were already loaded.
MSG
