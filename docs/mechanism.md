# Mechanism

This repository tracks the workstation-local Herdr/Codex/OMX glue, not a fork of
Herdr itself.

## Status flow

1. Herdr injects `HERDR_ENV=1`, `HERDR_SOCKET_PATH`, and `HERDR_PANE_ID` into panes it owns.
2. Codex hook events call `~/.codex/herdr-agent-state.sh`.
3. The hook reports `codex` agent state to Herdr's Unix socket with `pane.report_agent`.
4. `Stop` reports `idle`; `UserPromptSubmit` and ordinary `PreToolUse` report `working`.
5. OMX question renderer tool calls are mapped to `blocked`, so the sidebar shows human input wait correctly.
6. The zsh `omx()` wrapper propagates `HERDR_*` into newly-created tmux sessions.

The key reliability rule is: do not guess the pane from current focus. Only
explicit `HERDR_*` env, or values recovered from the current tmux session env,
are trusted.
