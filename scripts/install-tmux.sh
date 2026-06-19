#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stamp="$(date +%Y%m%d%H%M%S)"
backup_dir="$HOME/.tmux-local-config-backup-$stamp"
mkdir -p "$backup_dir"

backup_path() {
  local p="$1"
  if [ -e "$p" ] || [ -L "$p" ]; then
    mkdir -p "$backup_dir$(dirname "$p")"
    cp -a "$p" "$backup_dir$p"
  fi
}

move_aside() {
  local p="$1"
  [ -e "$p" ] || [ -L "$p" ] || return 0
  mkdir -p "$backup_dir$(dirname "$p")"
  mv "$p" "$backup_dir$p"
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing required command: $1" >&2
    exit 1
  }
}

origin_matches() {
  local dir="$1" expected="$2" origin
  origin="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
  [ "$origin" = "$expected" ] || [ "$origin" = "${expected%.git}.git" ] || [ "$origin" = "${expected%.git}" ]
}

sync_repo() {
  local dir="$1" url="$2" branch="$3"
  if [ ! -d "$dir/.git" ]; then
    move_aside "$dir"
    git clone --depth 1 --branch "$branch" "$url" "$dir"
    return
  fi
  if ! origin_matches "$dir" "$url"; then
    echo "Keeping existing git checkout with unexpected origin, moved aside: $dir" >&2
    move_aside "$dir"
    git clone --depth 1 --branch "$branch" "$url" "$dir"
    return
  fi
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null || true)" ] && [ "${HERDR_TMUX_FORCE:-0}" != "1" ]; then
    echo "error: $dir has local changes; set HERDR_TMUX_FORCE=1 to discard after backup." >&2
    exit 1
  fi
  git -C "$dir" fetch --depth 1 origin "$branch"
  git -C "$dir" checkout -q "$branch"
  if [ "${HERDR_TMUX_FORCE:-0}" = "1" ]; then
    git -C "$dir" reset -q --hard "origin/$branch"
  else
    git -C "$dir" pull --ff-only origin "$branch"
  fi
}

need git
need tmux

backup_path "$HOME/.tmux"
backup_path "$HOME/.tmux.conf"
backup_path "$HOME/.tmux.conf.local"
backup_path "$HOME/.config/tmux/plugins/catppuccin/tmux"
backup_path "$HOME/.config/tmux/plugins/tmux-plugins/tmux-cpu"

mkdir -p "$HOME/.config/tmux/plugins/catppuccin" "$HOME/.config/tmux/plugins/tmux-plugins"

sync_repo "$HOME/.tmux" "https://github.com/gpakosz/.tmux.git" master
sync_repo "$HOME/.config/tmux/plugins/catppuccin/tmux" "https://github.com/catppuccin/tmux.git" main
sync_repo "$HOME/.config/tmux/plugins/tmux-plugins/tmux-cpu" "https://github.com/tmux-plugins/tmux-cpu.git" master

cp "$repo_root/dotfiles/tmux/.tmux.conf.local" "$HOME/.tmux.conf.local"
rm -f "$HOME/.tmux.conf"
ln -s "$HOME/.tmux/.tmux.conf" "$HOME/.tmux.conf"
chmod 644 "$HOME/.tmux.conf.local"

echo "Installed tmux local config."
echo "Backup: $backup_dir"
echo "Use HERDR_TMUX_FORCE=1 only when you intentionally want to discard local plugin checkout changes after backup."
echo "Try: tmux -f \"$HOME/.tmux.conf\" new-session"
