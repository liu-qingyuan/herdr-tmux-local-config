#!/bin/sh
# installed by herdr
# safe to edit. this hook only activates inside herdr-managed panes.
# HERDR_INTEGRATION_ID=codex
# HERDR_INTEGRATION_VERSION=7

set -eu

action="${1:-}"
payload_file="$(mktemp "${TMPDIR:-/tmp}/herdr-codex-hook.XXXXXX")" || exit 0
trap 'rm -f "$payload_file"' EXIT HUP INT TERM
cat >"$payload_file" 2>/dev/null || true

case "$action" in
  session|working|idle|blocked|release) ;;
  *) exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 || exit 0

_hook_lib_dir="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || printf '%s' "$HOME/.codex")"
HERDR_ACTION="$action" HERDR_HOOK_INPUT_FILE="$payload_file" HERDR_HOOK_LIB_DIR="$_hook_lib_dir" python3 - <<'PY'
import json
import os
import random
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

for _path in (os.environ.get("HERDR_HOOK_LIB_DIR"), str(Path.home() / ".codex")):
    if _path and _path not in sys.path:
        sys.path.insert(0, _path)

from herdr_pane_binding import HerdrPaneBinding

SESSION_SOURCE = "herdr:codex"
STATUS_SOURCE = "codex"
AGENT = "codex"


def _trim(value):
    return value.strip() if isinstance(value, str) else ""


class HookPayload:
    def __init__(self, path):
        self.path = path or ""
        self.text = self._read_text()
        self.data = self._parse_json()

    def _read_text(self):
        if not self.path:
            return ""
        try:
            return Path(self.path).read_text(encoding="utf-8")
        except Exception:
            return ""

    def _parse_json(self):
        try:
            parsed = json.loads(self.text) if self.text.strip() else {}
        except Exception:
            parsed = {}
        return parsed if isinstance(parsed, dict) else {}

    @property
    def event(self):
        for key in ("hook_event_name", "hookEventName", "event"):
            value = self.data.get(key)
            if isinstance(value, str) and value:
                return value
        return ""

    @property
    def session_id(self):
        value = self.data.get("session_id")
        return value if isinstance(value, str) else ""

    def is_omx_question_tool(self):
        if self.event.lower() != "pretooluse":
            return False
        text = self.text.lower()
        return bool(re.search(r"omx(\.js)?(?:\\u0020|\s)+question|omx question", text))

    def normalize_action(self, requested_action):
        if requested_action == "working" and self.is_omx_question_tool():
            return "blocked"
        return requested_action


class CommandRunner:
    def text(self, argv, timeout=0.7):
        try:
            proc = subprocess.run(argv, check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
            if proc.returncode == 0:
                return proc.stdout or ""
        except Exception:
            pass
        return ""

    def json(self, argv, timeout=0.8):
        text = self.text(argv, timeout=timeout)
        if not text.strip():
            return {}
        try:
            parsed = json.loads(text)
        except Exception:
            return {}
        return parsed if isinstance(parsed, dict) else {}


class RuntimeContext:
    def __init__(self, runner):
        self.runner = runner
        self.env = dict(os.environ)
        self.recover_from_tmux_session()
        self.recover_socket_from_herdr_status()

    def recover_from_tmux_session(self):
        if self.env.get("HERDR_ENV") == "1" and self.env.get("HERDR_SOCKET_PATH") and self.env.get("HERDR_PANE_ID"):
            return
        if not self.env.get("TMUX"):
            return
        for name in ("HERDR_ENV", "HERDR_SOCKET_PATH", "HERDR_PANE_ID"):
            line = self.runner.text(["tmux", "show-environment", name], timeout=0.5).strip()
            if line.startswith(name + "="):
                self.env[name] = line.split("=", 1)[1]
                os.environ[name] = self.env[name]

    def recover_socket_from_herdr_status(self):
        if self.env.get("HERDR_SOCKET_PATH"):
            return
        status = self.runner.json(["herdr", "status", "server", "--json"], timeout=0.5)
        socket_path = status.get("socket") if isinstance(status, dict) else ""
        if socket_path:
            self.env["HERDR_SOCKET_PATH"] = str(socket_path)
            os.environ["HERDR_SOCKET_PATH"] = str(socket_path)

    @property
    def herdr_enabled(self):
        return self.env.get("HERDR_ENV") == "1" or bool(self.env.get("HERDR_SOCKET_PATH"))

    @property
    def socket_path(self):
        return self.env.get("HERDR_SOCKET_PATH") or str(Path.home() / ".config" / "herdr" / "herdr.sock")

    @property
    def explicit_pane_id(self):
        return self.env.get("HERDR_PANE_ID") or ""

    @property
    def tmux_session_name(self):
        if not self.env.get("TMUX"):
            return ""
        return self.runner.text(["tmux", "display-message", "-p", "#{session_name}"], timeout=0.5).strip()

    @property
    def cwd(self):
        try:
            return os.getcwd()
        except Exception:
            return ""

    def remember_pane_id(self, pane_id):
        if not pane_id:
            return
        self.env["HERDR_PANE_ID"] = pane_id
        os.environ["HERDR_PANE_ID"] = pane_id
        session = self.tmux_session_name
        if session:
            try:
                subprocess.run(["tmux", "set-environment", "-t", session, "HERDR_PANE_ID", pane_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=0.5)
            except Exception:
                pass


class HerdrPaneIndex:
    def __init__(self, runner):
        self.runner = runner
        self.binding = HerdrPaneBinding.from_herdr_cli(json_runner=self._runner_json)
        self.panes = self.binding.panes

    def _runner_json(self, argv, timeout=0.8):
        return self.runner.json(argv, timeout=timeout)

    def normalize_pane_id(self, pane_id):
        return self.binding.normalize(pane_id)

    def by_session(self, session_id):
        return self.binding.by_session(session_id)

class PaneResolver:
    def __init__(self, context, pane_index):
        self.context = context
        self.pane_index = pane_index

    def resolve(self, session_id=""):
        explicit_raw = self.context.explicit_pane_id
        explicit = self.pane_index.normalize_pane_id(explicit_raw)
        if explicit:
            self.context.remember_pane_id(explicit)
            return explicit
        session_matches = self.pane_index.by_session(session_id)
        if len(session_matches) == 1 and session_matches[0].get("pane_id"):
            pane_id = str(session_matches[0]["pane_id"])
            self.context.remember_pane_id(pane_id)
            return pane_id
        # Global Codex hooks must fail closed without a deterministic binding.
        # Focus/cwd guessing can overwrite another Herdr tab when multiple OMX
        # sessions share a workspace.
        return ""


class HerdrReporter:
    def __init__(self, socket_path):
        self.socket_path = socket_path

    def send(self, method, params, source):
        request_id = f"{source}:{int(time.time() * 1000)}:{random.randrange(1_000_000):06d}"
        request = {"id": request_id, "method": method, "params": params}
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(0.5)
            client.connect(self.socket_path)
            client.sendall((json.dumps(request) + "\n").encode())
            try:
                client.recv(4096)
            except Exception:
                pass
            client.close()
        except Exception:
            pass

    def report_session(self, pane_id, session_id):
        if not session_id:
            return
        self.send(
            "pane.report_agent_session",
            {"pane_id": pane_id, "source": SESSION_SOURCE, "agent": AGENT, "seq": time.time_ns(), "agent_session_id": session_id},
            SESSION_SOURCE,
        )

    def release(self, pane_id):
        self.send(
            "pane.release_agent",
            {"pane_id": pane_id, "source": STATUS_SOURCE, "agent": AGENT, "seq": time.time_ns()},
            STATUS_SOURCE,
        )

    def report_status(self, pane_id, state, session_id=""):
        params = {"pane_id": pane_id, "source": STATUS_SOURCE, "agent": AGENT, "state": state, "seq": time.time_ns()}
        if session_id:
            params["agent_session_id"] = session_id
        self.send(
            "pane.report_agent",
            params,
            STATUS_SOURCE,
        )


class Controller:
    def __init__(self):
        self.runner = CommandRunner()
        self.payload = HookPayload(os.environ.get("HERDR_HOOK_INPUT_FILE"))
        self.context = RuntimeContext(self.runner)
        self.pane_index = HerdrPaneIndex(self.runner)
        self.resolver = PaneResolver(self.context, self.pane_index)
        self.reporter = HerdrReporter(self.context.socket_path)
        self.action = self.payload.normalize_action(os.environ.get("HERDR_ACTION", ""))

    def run(self):
        if not self.context.herdr_enabled:
            return 0
        pane_id = self.resolver.resolve(self.payload.session_id)
        if not pane_id:
            return 0
        if self.action == "session":
            self.reporter.report_session(pane_id, self.payload.session_id)
        elif self.action == "release":
            self.reporter.release(pane_id)
        elif self.action in ("working", "idle", "blocked"):
            self.reporter.report_status(pane_id, self.action, self.payload.session_id)
            # Herdr 0.7 keeps visible status (`source=codex`) and session
            # identity (`source=herdr:codex`) as separate authorities. A status
            # update can clear the visible agent_session field, so refresh the
            # session binding after every status report when Codex provided it.
            self.reporter.report_session(pane_id, self.payload.session_id)
        return 0


raise SystemExit(Controller().run())
PY
