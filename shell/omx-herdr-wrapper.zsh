# Herdr-aware OMX launcher.
# Source this from ~/.zshrc after installing oh-my-codex and Herdr.
# It preserves HERDR_* pane identity when launching OMX in a fresh tmux session,
# so Codex hooks can report state to the correct Herdr pane without guessing.

_herdr_omx_find_bin() {
  local candidate
  for candidate in \
    "${HERDR_OMX_BIN:-}" \
    "$HOME/.local/bin/omx" \
    "$HOME/.npm-global/bin/omx" \
    "/opt/homebrew/bin/omx" \
    "/usr/local/bin/omx"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  command -v omx 2>/dev/null
}

_omx_launch() {
  local omx_bin
  omx_bin="$(_herdr_omx_find_bin)" || return 127
  [ -n "$omx_bin" ] || { echo 'omx not found' >&2; return 127; }

  if [ -n "${TMUX:-}" ] || ! command -v tmux >/dev/null 2>&1 || [ ! -t 0 ] || [ ! -t 1 ]; then
    command "$omx_bin" "$@"
    return
  fi

  local session_name="omx-shell-${RANDOM}-$$"
  local quoted_args=""
  local arg quoted_bin
  local tmux_env_args=()

  if [ "${HERDR_ENV:-}" = "1" ]; then
    tmux_env_args+=(-e "HERDR_ENV=${HERDR_ENV}")
    [ -n "${HERDR_SOCKET_PATH:-}" ] && tmux_env_args+=(-e "HERDR_SOCKET_PATH=${HERDR_SOCKET_PATH}")
    [ -n "${HERDR_PANE_ID:-}" ] && tmux_env_args+=(-e "HERDR_PANE_ID=${HERDR_PANE_ID}")
  fi

  for arg in "$@"; do
    quoted_args+=" ${(q)arg}"
  done
  quoted_bin="${(q)omx_bin}"

  tmux new-session "${tmux_env_args[@]}" -s "$session_name" -c "$PWD" "exec ${quoted_bin}${quoted_args}"
}

omx() {
  _omx_launch "$@"
}

omx-max() {
  local extra_args=(--madmax)
  local has_reasoning=0
  local arg

  for arg in "$@"; do
    case "$arg" in
      --high|--xhigh|-c|model_reasoning_effort=*|-c=model_reasoning_effort=*)
        has_reasoning=1
        ;;
    esac
  done

  if [ "$has_reasoning" -eq 0 ]; then
    extra_args+=(--high)
  fi

  _omx_launch "${extra_args[@]}" "$@"
}
