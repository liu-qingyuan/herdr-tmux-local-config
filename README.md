# herdr-local-config

Local configuration for using [Herdr](https://github.com/ogulcancelik/herdr) with
Codex and oh-my-codex (OMX) on this workstation family.

This is **not** a Herdr fork. Herdr itself is installed from upstream release
binaries; this repo tracks our local dotfile-level integration:

- Herdr UI config (`agent_panel_scope = "current"`, pane border labels, theme/keybinding).
- Herdr helper script for focusing the next tab.
- Codex hook script that reports `working`, `idle`, and `blocked` to Herdr.
- Minimal Codex hook JSON fragment for the Herdr state hook.
- zsh OMX wrapper that preserves `HERDR_*` through tmux sessions.

## Layout

```text
dotfiles/herdr/config.toml                  # ~/.config/herdr/config.toml
dotfiles/herdr/scripts/focus-next-tab.py    # ~/.config/herdr/scripts/focus-next-tab.py
dotfiles/codex/herdr-agent-state.sh         # ~/.codex/herdr-agent-state.sh
dotfiles/codex/hooks.herdr.json             # fragment to merge into ~/.codex/hooks.json
shell/omx-herdr-wrapper.zsh                 # zsh functions for omx/omx-max
scripts/install.sh                          # copies managed files with timestamped backups
scripts/verify.sh                           # syntax and simple secret-pattern checks
```

## Install

```bash
./scripts/install.sh
```

Then manually merge:

1. `dotfiles/codex/hooks.herdr.json` into `~/.codex/hooks.json` if those events are missing.
2. `source /path/to/herdr-local-config/shell/omx-herdr-wrapper.zsh` into `~/.zshrc`, or merge the functions manually.

Reload Herdr after config changes:

```bash
herdr server reload-config || true
```

## Verify

```bash
./scripts/verify.sh
herdr --version
python3 -m json.tool ~/.codex/hooks.json >/dev/null
sh -n ~/.codex/herdr-agent-state.sh
zsh -n ~/.zshrc
```

For a live mechanism check, launch Codex/OMX inside Herdr and confirm the pane
state moves through `working`/`idle` without reporting into the wrong tab.

## Security notes

Do not commit full `~/.codex/config.toml`, auth files, SSH keys, tokens, or
machine-specific secrets. Keep this repository to portable Herdr integration
configuration only.
