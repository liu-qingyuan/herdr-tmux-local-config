# herdr-tmux-local-config

Local configuration for using [Herdr](https://github.com/ogulcancelik/herdr),
Codex/oh-my-codex (OMX), and Oh My Tmux on this workstation family.

This is **not** a Herdr fork. Herdr itself is installed from upstream release
binaries; this repo tracks our local dotfile-level integration:

- Herdr UI config (`agent_panel_scope = "current"`, pane border labels, theme/keybinding).
- Herdr helper script for focusing the next tab.
- Codex hook script that reports `working`, `idle`, and `blocked` to Herdr.
- Minimal Codex hook JSON fragment for the Herdr state hook.
- zsh OMX wrapper that finds `omx` across Linux/macOS install paths and preserves `HERDR_*` through tmux sessions.

## Layout

```text
dotfiles/herdr/config.toml                  # ~/.config/herdr/config.toml
dotfiles/herdr/scripts/focus-next-tab.py    # ~/.config/herdr/scripts/focus-next-tab.py
dotfiles/codex/herdr-agent-state.sh         # ~/.codex/herdr-agent-state.sh
dotfiles/codex/herdr-omx-state.sh           # ~/.codex/herdr-omx-state.sh
dotfiles/codex/hooks.herdr.json             # fragment to merge into ~/.codex/hooks.json
dotfiles/tmux/.tmux.conf.local              # ~/.tmux.conf.local for Oh My Tmux + Catppuccin
dotfiles/tmux/README.md                     # tmux layout notes
shell/omx-herdr-wrapper.zsh                 # zsh functions for omx/omx-max
scripts/install.sh                          # copies managed Herdr/Codex files with timestamped backups
scripts/install-tmux.sh                     # installs Oh My Tmux + Catppuccin tmux config
scripts/verify.sh                           # syntax and simple secret-pattern checks
```

## Install

```bash
./scripts/install.sh
./scripts/install-tmux.sh
```

`install-tmux.sh` installs/updates Oh My Tmux (`gpakosz/.tmux`), Catppuccin tmux,
and `tmux-cpu`, then links `~/.tmux.conf` and installs the tracked
`~/.tmux.conf.local`.

Then manually merge:

1. `dotfiles/codex/hooks.herdr.json` into `~/.codex/hooks.json` if those events are missing.
2. `source /path/to/herdr-local-config/shell/omx-herdr-wrapper.zsh` into `~/.zshrc`, or merge the functions manually. Set `HERDR_OMX_BIN=/path/to/omx` only if `omx` is not on a standard Linux/macOS path.

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
state moves through `working`/`idle` without reporting into the wrong tab, including after Herdr restore/reopen where injected `p_N` ids may no longer match live public pane ids.

## Security notes

Do not commit full `~/.codex/config.toml`, auth files, SSH keys, tokens, or
machine-specific secrets. Keep this repository to portable Herdr, OMX, and tmux
integration configuration only.
