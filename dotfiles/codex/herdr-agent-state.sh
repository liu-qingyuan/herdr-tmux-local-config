#!/bin/sh
# installed by herdr
# safe to edit. this hook only activates inside herdr-managed panes.
# HERDR_INTEGRATION_ID=codex
# HERDR_INTEGRATION_VERSION=2

set -eu

action="${1:-}"
_payload="$(cat 2>/dev/null || true)"

# Codex exposes generic hook events. Herdr's stock mapping marks
# UserPromptSubmit/PreToolUse as working and Stop as idle. For OMX-owned user
# choice prompts, PreToolUse sees the upcoming renderer command before the
# temporary UI blocks on human input. Report that state as blocked so Herdr
# shows that the agent is waiting for the user instead of still working.
case "$action" in
  working)
    case "$_payload" in
      *'"hook_event_name":"PreToolUse"'*|*'"hookEventName":"PreToolUse"'*|*'"event":"PreToolUse"'*)
        case "$_payload" in
          *'omx question'*|*'omx.js question'*) action="blocked" ;;
        esac
        ;;
    esac
    ;;
esac

case "$action" in
  working|idle|blocked|release) ;;
  *) exit 0 ;;
esac

# Herdr injects HERDR_* into panes it owns. When Codex is launched through
# OMX -> tmux and the tmux server was already running, tmux can drop those
# variables from the Codex process environment. Recover them from the current
# tmux session environment when possible, so the integration still works in
# Herdr-managed OMX/tmux panes.
if [ "${HERDR_ENV:-}" != "1" ] || [ -z "${HERDR_SOCKET_PATH:-}" ] || [ -z "${HERDR_PANE_ID:-}" ]; then
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    _herdr_env="$(tmux show-environment HERDR_ENV 2>/dev/null || true)"
    _herdr_socket="$(tmux show-environment HERDR_SOCKET_PATH 2>/dev/null || true)"
    _herdr_pane="$(tmux show-environment HERDR_PANE_ID 2>/dev/null || true)"
    case "$_herdr_env" in HERDR_ENV=*) export HERDR_ENV="${_herdr_env#HERDR_ENV=}" ;; esac
    case "$_herdr_socket" in HERDR_SOCKET_PATH=*) export HERDR_SOCKET_PATH="${_herdr_socket#HERDR_SOCKET_PATH=}" ;; esac
    case "$_herdr_pane" in HERDR_PANE_ID=*) export HERDR_PANE_ID="${_herdr_pane#HERDR_PANE_ID=}" ;; esac
  fi
fi

# Do not guess HERDR_PANE_ID from the currently focused Herdr pane. A Codex
# hook can fire while focus has moved to a plain shell tab; focused-pane
# guessing then reports `codex` into the wrong tab. Only explicit Herdr env
# or tmux session env is trusted.

[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_SOCKET_PATH:-}" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

HERDR_ACTION="$action" python3 - <<'PY'
import json
import os
import random
import socket
import time

source = "herdr:codex"
action = os.environ.get("HERDR_ACTION", "")
pane_id = os.environ.get("HERDR_PANE_ID")
socket_path = os.environ.get("HERDR_SOCKET_PATH")

if not pane_id or not socket_path:
    raise SystemExit(0)

request_id = f"{source}:{int(time.time() * 1000)}:{random.randrange(1_000_000):06d}"
report_seq = time.time_ns()
if action == "release":
    request = {
        "id": request_id,
        "method": "pane.release_agent",
        "params": {
            "pane_id": pane_id,
            "source": source,
            "agent": "codex",
            "seq": report_seq,
        },
    }
else:
    request = {
        "id": request_id,
        "method": "pane.report_agent",
        "params": {
            "pane_id": pane_id,
            "source": source,
            "agent": "codex",
            "state": action,
            "seq": report_seq,
        },
    }

try:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.5)
    client.connect(socket_path)
    client.sendall((json.dumps(request) + "\n").encode())
    try:
        client.recv(4096)
    except Exception:
        pass
    client.close()
except Exception:
    pass
PY
