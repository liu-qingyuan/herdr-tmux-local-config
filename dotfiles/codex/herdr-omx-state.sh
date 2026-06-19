#!/bin/sh
# OMX -> Herdr status bridge.
# Companion to Herdr's official Codex v5 session hook. This hook reports
# semantic OMX runtime state (working/blocked/idle/unknown) for Herdr HUDs.
set -eu

_payload_file="$(mktemp "${TMPDIR:-/tmp}/herdr-omx-hook.XXXXXX")" || exit 0
trap 'rm -f "$_payload_file"' EXIT HUP INT TERM
cat >"$_payload_file" 2>/dev/null || true

# Only activate for OMX-managed Codex sessions.
[ -n "${OMX_SESSION_ID:-}${OMXBOX_ACTIVE:-}${OMX_ROOT:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

# Herdr injects HERDR_* into panes it owns, but OMX/tmux can drop those vars
# from the Codex process environment. Recover the explicit Herdr pane/socket
# from the current tmux session before falling back to Herdr CLI lookup.
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

_hook_lib_dir="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || printf '%s' "$HOME/.codex")"
HERDR_OMX_HOOK_INPUT_FILE="$_payload_file" HERDR_HOOK_LIB_DIR="$_hook_lib_dir" python3 - <<'PY'
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

from herdr_pane_binding import HerdrPaneBinding, load_live_panes

source = "herdr:omx"
cwd = os.getcwd()
hook_input_file = os.environ.get("HERDR_OMX_HOOK_INPUT_FILE") or ""


def read_payload():
    text = ""
    data = {}
    if hook_input_file:
        try:
            with open(hook_input_file, encoding="utf-8") as handle:
                text = handle.read()
            if text.strip():
                data = json.loads(text)
        except Exception:
            data = {}
    return text, data if isinstance(data, dict) else {}


def run_json(argv, timeout=0.8):
    try:
        proc = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
        if proc.returncode == 0 and proc.stdout.strip():
            return json.loads(proc.stdout)
    except Exception:
        pass
    return None


def hook_event_name(payload):
    for key in ("hook_event_name", "hookEventName", "event"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def is_omx_question(payload_text):
    lowered = payload_text.lower()
    # Reference: liu-qingyuan/herdr-local-config maps Codex PreToolUse that is
    # about to run the OMX question renderer to Herdr blocked. Match both CLI
    # and bundled node entrypoint forms, plus JSON-escaped payloads.
    needles = (
        "omx question",
        "omx.js question",
        "omx\\u0020question",
        "omx.js\\u0020question",
    )
    return any(needle in lowered for needle in needles)


def run_text(argv, timeout=0.8):
    try:
        proc = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
        if proc.returncode == 0:
            return proc.stdout or ""
    except Exception:
        pass
    return ""



def read_json_file(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return None


def state_roots():
    roots = []
    omx_root = os.environ.get("OMX_ROOT") or ""
    session_id = os.environ.get("OMX_SESSION_ID") or codex_thread_id or ""
    if omx_root and session_id:
        # Per-session table is authoritative. The shared state directory can
        # contain stale/project-wide modes from another Codex tab.
        roots.append(os.path.join(omx_root, ".omx", "state", "sessions", session_id))
    return roots


def turn_state_path():
    roots = state_roots()
    if not roots:
        return ""
    return os.path.join(roots[0], "herdr-omx-turn-state.json")


def persist_turn_state(state, custom_status, event):
    path = turn_state_path()
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({
                "version": 1,
                "state": state,
                "custom_status": custom_status,
                "event": event,
                "session_id": os.environ.get("OMX_SESSION_ID") or codex_thread_id,
                "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "updated_monotonic": time.monotonic(),
            }, handle, ensure_ascii=False, indent=2)
    except Exception:
        pass


def format_state_label(mode, data):
    phase = None
    if isinstance(data, dict):
        phase = data.get("current_phase") or data.get("phase") or data.get("status")
        story = data.get("current_story") or data.get("story") or data.get("goal_id") or data.get("current_goal")
        if story and phase:
            return f"{mode}:{phase}:{str(story)[:48]}"
        if phase:
            return f"{mode}:{phase}"
    return str(mode)


def summarize_boxed_session_state():
    """Return (has_active, custom_status) from this hook's own OMX state table.

    Do not call `omx state list-active` from the project cwd here: with multiple
    OMX/Codex dialogs and different CODEX_HOME/OMX_ROOT values, that command can
    read the project-local/shared table and return stale modes for another tab.
    The bridge must read the boxed root/session files for the hook process.
    """
    labels = []
    inactive_seen = []
    for root in state_roots():
        skill_state = read_json_file(os.path.join(root, "skill-active-state.json"))
        if isinstance(skill_state, dict):
            active_skills = skill_state.get("active_skills")
            if isinstance(active_skills, list):
                for item in active_skills:
                    if isinstance(item, dict) and item.get("active") is True:
                        skill = item.get("skill") or skill_state.get("skill") or skill_state.get("initialized_mode") or "omx"
                        phase = item.get("phase") or skill_state.get("phase")
                        labels.append(f"{skill}:{phase}" if phase else str(skill))
            if skill_state.get("active") is True and not labels:
                skill = skill_state.get("skill") or skill_state.get("initialized_mode") or "omx"
                phase = skill_state.get("phase")
                labels.append(f"{skill}:{phase}" if phase else str(skill))
            elif skill_state.get("active") is False:
                inactive_seen.append(skill_state.get("skill") or skill_state.get("initialized_mode") or "omx")

        # Mode-specific state files in this exact root/session.
        try:
            names = sorted(os.listdir(root))
        except Exception:
            names = []
        for name in names:
            if not name.endswith("-state.json") or name in ("skill-active-state.json", "hud-state.json", "prompt-routing-state.json", "notify-hook-state.json", "herdr-omx-turn-state.json"):
                continue
            data = read_json_file(os.path.join(root, name))
            if not isinstance(data, dict):
                continue
            mode = data.get("mode") or name[:-len("-state.json")]
            if data.get("active") is True:
                label = format_state_label(mode, data)
                if label not in labels:
                    labels.append(label)
            elif data.get("active") is False:
                inactive_seen.append(str(mode))

    if labels:
        return True, "OMX " + ", ".join(labels[:3])
    return False, "OMX idle"

payload_text, payload = read_payload()
payload_session_id = payload.get("session_id") if isinstance(payload.get("session_id"), str) else ""
# Herdr treats idle reports without an agent_session_id as terminal/done in some
# cases. For OMX-managed Codex homes, the process always has OMX_SESSION_ID even
# when a manual reconciliation/no-event hook has no Codex payload. Use it as the
# stable session identity so idle remains idle instead of becoming done.
codex_thread_id = payload_session_id or os.environ.get("CODEX_THREAD_ID") or os.environ.get("OMX_SESSION_ID") or ""
event = hook_event_name(payload)
event_l = event.lower()

# Semantic state mapping: keep Codex turn state separate from OMX mode labels.
#
# Herdr's official Codex v5 integration only reports the session identity. The
# local status bridge reports busy/idle from Codex hook lifecycle only. OMX
# workflow/mode files contribute custom_status labels, but never make an idle
# Codex prompt appear working.
has_active = False
custom_status = "OMX runtime"
if os.environ.get("OMX_SESSION_ID") or os.environ.get("OMXBOX_ACTIVE") or os.environ.get("OMX_ROOT"):
    has_active, custom_status = summarize_boxed_session_state()

# Resolve pane before final fallback decisions so no-event reconciliation can
# inspect the bound pane. This block is duplicated later only after socket setup
# in older versions; keep the same strict mapping rules.
_pre_status = run_json(["herdr", "status", "server", "--json"]) or {}
_pre_pane_list = run_json(["herdr", "pane", "list", "--json"]) or run_json(["herdr", "pane", "list"]) or {}
if isinstance(_pre_pane_list, dict) and isinstance(_pre_pane_list.get("result"), dict):
    _pre_panes = _pre_pane_list.get("result", {}).get("panes") or []
else:
    _pre_panes = []
_pre_explicit = os.environ.get("HERDR_PANE_ID") or ""
_pre_explicit_matches = [p for p in _pre_panes if p.get("pane_id") == _pre_explicit] if _pre_explicit else []
_pre_session_matches = [p for p in _pre_panes if ((p.get("agent_session") or {}).get("value") == codex_thread_id)] if codex_thread_id else []
if _pre_explicit_matches:
    _pre_candidates = _pre_explicit_matches
elif _pre_session_matches:
    _pre_candidates = _pre_session_matches
else:
    _pre_candidates = []
_pre_pane_id = str(_pre_candidates[0].get("pane_id") or "") if len(_pre_candidates) == 1 else ""


def pane_binding():
    panes = _pre_panes if isinstance(_pre_panes, list) and _pre_panes else load_live_panes(json_runner=lambda argv, timeout=0.8: run_json(argv, timeout) or {})
    return HerdrPaneBinding(panes)


def live_public_resolver():
    return pane_binding().local_map

def herdr_session_spawn_pid_map():
    session_path = Path.home() / ".config" / "herdr" / "session.json"
    data = read_json_file(str(session_path))
    wanted = set()
    if isinstance(data, dict):
        for ws in data.get("workspaces") or []:
            for tab in ws.get("tabs") or []:
                wanted.update(str(k) for k in (tab.get("panes") or {}).keys())
    if not wanted:
        return {}
    latest = {}
    log_path = Path.home() / ".config" / "herdr" / "herdr-server.log"
    try:
        for line in log_path.read_text(errors="ignore").splitlines():
            m = re.search(r"pane child spawned .*pane_id=(\d+) pid=(\d+)", line)
            if m and m.group(1) in wanted:
                latest[m.group(1)] = int(m.group(2))
    except Exception:
        pass
    local_map = live_public_resolver()
    out = {}
    if isinstance(data, dict):
        for ws in data.get("workspaces") or []:
            wid = ws.get("id")
            if not wid:
                continue
            for idx, tab in enumerate(ws.get("tabs") or [], start=1):
                tab_public_fallback = local_map.get(f"{wid}:t{idx}") or local_map.get(f"{wid}:{idx}")
                for local_id in (tab.get("panes") or {}).keys():
                    local_id = str(local_id)
                    pid = latest.get(local_id)
                    public = local_map.get(local_id) or tab_public_fallback or ""
                    if pid and public:
                        out[pid] = public
    return out


def current_tmux_session_name():
    return run_text(["tmux", "display-message", "-p", "#{session_name}"], timeout=0.5).strip()


def persist_omx_env_to_tmux():
    session = current_tmux_session_name()
    if not session:
        return
    for key in ("OMX_SESSION_ID", "OMX_ROOT"):
        value = os.environ.get(key) or ""
        if not value:
            continue
        try:
            subprocess.run(["tmux", "set-environment", "-t", session, key, value], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=0.5)
        except Exception:
            pass


persist_omx_env_to_tmux()


def tmux_client_tty(session):
    if not session:
        return ""
    text = run_text(["tmux", "list-clients", "-t", session, "-F", "#{client_tty}"], timeout=0.5)
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("/dev/pts/"):
            return line
    return ""


def tty_root_pid(tty):
    if not tty.startswith("/dev/"):
        return None
    text = run_text(["ps", "-t", tty.replace("/dev/", ""), "-o", "pid=,ppid=,stat=,cmd="], timeout=0.5)
    rows = []
    for line in text.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) >= 4:
            try:
                rows.append((int(parts[0]), int(parts[1]), parts[2], parts[3]))
            except Exception:
                pass
    if not rows:
        return None
    pids = {row[0] for row in rows}
    for row in rows:
        if row[1] not in pids:
            return row[0]
    return rows[0][0]


def infer_pane_from_tmux_client():
    session = current_tmux_session_name()
    tty = tmux_client_tty(session)
    pid = tty_root_pid(tty) if tty else None
    if not pid:
        return ""
    return herdr_session_spawn_pid_map().get(pid, "")

_pre_live_pane_ids = {str(p.get("pane_id") or "") for p in _pre_panes if isinstance(p, dict) and p.get("pane_id")}
_inferred_pane = infer_pane_from_tmux_client()
if _inferred_pane and _inferred_pane in _pre_live_pane_ids:
    # Attached tmux client tty -> current live Herdr pane spawn pid is stronger
    # than inherited tmux HERDR_PANE_ID. Ignore stale session.json/log mappings
    # that point to panes absent from Herdr's live pane list.
    os.environ["HERDR_PANE_ID"] = _inferred_pane
    try:
        subprocess.run(["tmux", "set-environment", "-t", current_tmux_session_name(), "HERDR_PANE_ID", _inferred_pane], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=0.5)
    except Exception:
        pass
elif tmux_client_tty(current_tmux_session_name()):
    # This OMX session is attached, but not through a current live Herdr pane.
    # Avoid reporting into a stale explicit pane binding. Final resolution below
    # still fails closed unless an explicit pane or session match is available.
    if (os.environ.get("HERDR_PANE_ID") or "") not in _pre_live_pane_ids:
        os.environ.pop("HERDR_PANE_ID", None)

if event_l == "pretooluse" and is_omx_question(payload_text):
    state = "blocked"
    custom_status = "OMX waiting for user"
elif event_l in ("userpromptsubmit", "pretooluse", "precompact"):
    # This is an edge-trigger from Codex: the turn/tool is starting.
    state = "working"
    if not has_active:
        custom_status = "OMX runtime"
elif event_l in ("stop", "sessionstart", "postcompact"):
    # Stop/SessionStart/PostCompact are not active-turn signals. Even if OMX
    # workflow state files remain active (e.g. code-review:planning), Herdr's
    # primary state should be idle unless a later UserPromptSubmit/PreToolUse
    # marks a fresh Codex turn as working. Keep OMX labels in custom_status.
    state = "idle"
    if not has_active:
        custom_status = "OMX idle"
elif event_l == "posttooluse":
    # PostToolUse is not a turn-complete signal. Preserve prior status until the
    # Stop hook arrives. This matches the reference local-config behavior.
    raise SystemExit(0)
elif os.environ.get("OMX_SESSION_ID") or os.environ.get("OMXBOX_ACTIVE") or os.environ.get("OMX_ROOT"):
    # No fresh Codex hook event: reconcile labels from this exact boxed session,
    # but do not infer busy from mode files, focus/cwd, or visible terminal text.
    # This makes stale active workflow files such as pending BUG/code-review show
    # idle when Codex is waiting at the prompt.
    state = "idle"
    if not has_active:
        custom_status = "OMX idle"
else:
    state = "unknown"
    custom_status = "OMX unknown"

persist_turn_state(state, custom_status, event)

status = _pre_status
socket_path = os.environ.get("HERDR_SOCKET_PATH") or status.get("socket") or os.path.expanduser("~/.config/herdr/herdr.sock")

pane_list = run_json(["herdr", "pane", "list", "--json"]) or run_json(["herdr", "pane", "list"]) or {}
if isinstance(pane_list, dict) and isinstance(pane_list.get("result"), dict):
    panes = pane_list.get("result", {}).get("panes") or []
else:
    panes = []


def live_pane_ids(items):
    return {str(p.get("pane_id") or "") for p in items if isinstance(p, dict) and p.get("pane_id")}


# Correct mapping priority for multi-OMX / multi-Codex tabs:
# 1) explicit Herdr pane recovered from the current tmux *session* env, but only
#    if it still exists in the current workspace;
# 2) existing Herdr agent_session match for the current hook payload/session id;
# 3) otherwise no report.
# Do not use focused-pane or focused+cwd fallback here. Multiple OMX dialogs can
# share cwd and tmux server; focus guessing lets a completed session overwrite a
# different running tab as idle.
explicit_pane_id = os.environ.get("HERDR_PANE_ID") or ""
local_pane_map = live_public_resolver()
normalized_explicit_pane_id = explicit_pane_id if explicit_pane_id in live_pane_ids(panes) else local_pane_map.get(explicit_pane_id, "")
explicit_matches = [p for p in panes if p.get("pane_id") == normalized_explicit_pane_id] if normalized_explicit_pane_id else []
session_matches = [p for p in panes if ((p.get("agent_session") or {}).get("value") == codex_thread_id)] if codex_thread_id else []
if explicit_matches:
    candidates = explicit_matches
elif session_matches:
    candidates = session_matches
else:
    # Global hook: no focus/cwd fallback. Without a deterministic pane binding
    # or existing session match, reporting could update the wrong Herdr tab.
    candidates = []

if len(candidates) != 1 or not candidates[0].get("pane_id"):
    raise SystemExit(0)
pane_id = str(candidates[0]["pane_id"])
if pane_id != explicit_pane_id:
    os.environ["HERDR_PANE_ID"] = pane_id
    try:
        subprocess.run(["tmux", "set-environment", "-t", current_tmux_session_name(), "HERDR_PANE_ID", pane_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=0.5)
    except Exception:
        pass

seq = str(time.time_ns())
# Do not release before a Stop/idle hook report. Herdr uses the first
# working->idle transition to show its finish/done attention state. The
# reconcile watcher clears that attention state back to stable idle after TTL.
# Prefer the Herdr CLI for the actual report: it tracks current Herdr API
# behavior exactly. Fall back to the socket only if the CLI report command is
# unavailable/fails.
cli_cmd = [
    "herdr", "pane", "report-agent", pane_id,
    "--source", source,
    "--agent", "omx",
    "--state", state,
    "--message", custom_status,
    "--custom-status", custom_status,
    "--seq", seq,
]
if codex_thread_id:
    cli_cmd.extend(["--agent-session-id", codex_thread_id])
try:
    proc = subprocess.run(cli_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1.0)
    if proc.returncode == 0:
        # Reconcile all explicit OMX<->Herdr pane bindings in the background so
        # tabs that do not receive a fresh Codex hook still converge to the
        # correct generic state. This is intentionally global but strict: the
        # helper trusts only per-session hook state and OMX labels; it never
        # guesses from focus/cwd/visible text/title spinners.
        helper = os.path.expanduser("~/.local/bin/herdr-omx-reconcile")
        if os.path.exists(helper) and not os.environ.get("HERDR_OMX_RECONCILING"):
            try:
                subprocess.Popen([helper], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env={**os.environ, "HERDR_OMX_RECONCILING": "1"})
            except Exception:
                pass
        raise SystemExit(0)
except SystemExit:
    raise
except Exception:
    pass

request = {
    "id": f"{source}:{int(time.time()*1000)}:{random.randrange(1_000_000):06d}",
    "method": "pane.report_agent",
    "params": {
        "pane_id": pane_id,
        "source": source,
        "agent": "omx",
        "state": state,
        "message": custom_status,
        "custom_status": custom_status,
        "seq": int(seq),
        **({"agent_session_id": codex_thread_id} if codex_thread_id else {}),
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
