#!/usr/bin/env bash
set -euo pipefail

python3 -m json.tool dotfiles/codex/hooks.herdr.json >/dev/null
[ ! -e dotfiles/herdr/scripts/focus-next-tab.py ] || python3 -m py_compile dotfiles/herdr/scripts/focus-next-tab.py
sh -n dotfiles/codex/herdr-agent-state.sh
sh -n dotfiles/codex/herdr-omx-state.sh
python3 -m py_compile dotfiles/local/bin/herdr-omx-reconcile
bash -n dotfiles/local/bin/herdr-omx-reconcile-watch
if command -v zsh >/dev/null 2>&1; then
  zsh -n shell/omx-herdr-wrapper.zsh
else
  echo "WARN: zsh not found; skipping shell/omx-herdr-wrapper.zsh syntax check." >&2
fi

if grep -RInE '(gho_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+|api[_-]?key[[:space:]]*=|token[[:space:]]*=|password[[:space:]]*=|private_key[[:space:]]*=)' . \
  --exclude-dir=.git \
  --exclude='verify.sh'; then
  echo 'Potential secret-like content found; inspect before committing.' >&2
  exit 1
fi

echo 'OK: config templates parse and no obvious secret patterns were found.'
