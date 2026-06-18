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

## OMX semantic status bridge

`herdr-agent-state.sh` remains the stock Codex session identity hook. OMX status
is reported by the companion `herdr-omx-state.sh` plus the background
`herdr-omx-reconcile-watch` helper.

The reconcile helper follows these rules:

- Read only the boxed session table: `OMX_ROOT/.omx/state/sessions/$OMX_SESSION_ID`.
- Treat Codex hook turn-state as authoritative when present and fresh.
- Treat workflow state files as labels only; stale `active:true` files do not make
  a completed tab appear busy.
- For legacy sessions without turn-state, use the live tmux title spinner only as
  a fallback.
- Support both Herdr public pane ids (`w...-N`) and newer local injected ids
  (`p_N`) by translating through `~/.config/herdr/session.json` tab identity and the current live `herdr pane list` result. This handles restore/reopen cases where `session.json` still names `p_6` but the live tab is exposed as a different public pane id.
- Preserve Herdr's first `working -> idle` finish/done attention transition, then
  let the watcher converge stale finish/done back to stable idle after the TTL.

This avoids broad focus/cwd guessing while still recovering after Herdr restarts,
restore/reopen churn, or newer Herdr versions injecting local pane ids into the shell environment. The only focus fallback is bounded to one focused live pane in the same cwd when the explicit binding is missing or stale.
