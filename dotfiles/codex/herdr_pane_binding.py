"""Shared Herdr pane binding helpers for Codex/OMX status bridges.

Herdr 0.7 stores local numeric pane ids in session.json while the live API uses
workspace-qualified public ids such as ``w...:pA``. This module is the single
contract for translating legacy/local ids to live public ids and for finding
panes already bound to a Codex/OMX session.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any, Callable

JsonRunner = Callable[[list[str], float], dict[str, Any]]


def base36(value: Any) -> str:
    try:
        number = int(value)
    except Exception:
        return str(value)
    if number < 0:
        return str(value)
    digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    if number < 36:
        return digits[number]
    out = ""
    while number:
        number, rem = divmod(number, 36)
        out = digits[rem] + out
    return out or "0"


def read_json_file(path: str | Path) -> dict[str, Any]:
    try:
        parsed = json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        parsed = {}
    return parsed if isinstance(parsed, dict) else {}


def run_json(argv: list[str], timeout: float = 0.8) -> dict[str, Any]:
    try:
        proc = subprocess.run(argv, check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
        if proc.returncode == 0 and proc.stdout.strip():
            parsed = json.loads(proc.stdout)
            return parsed if isinstance(parsed, dict) else {}
    except Exception:
        pass
    return {}


def load_live_panes(json_runner: JsonRunner | None = None) -> list[dict[str, Any]]:
    runner = json_runner or run_json
    for argv in (["herdr", "pane", "list", "--json"], ["herdr", "pane", "list"]):
        data = runner(argv, 0.8)
        result = data.get("result") if isinstance(data, dict) else None
        panes = result.get("panes") if isinstance(result, dict) else None
        if isinstance(panes, list):
            return [p for p in panes if isinstance(p, dict)]
    return []


class HerdrPaneBinding:
    """Resolve Herdr local/legacy pane ids against the current live pane list.

    The resolver deliberately fails closed. A local id is accepted only when it
    can be mapped through Herdr session.json and confirmed against live pane/tab
    metadata. Focus or cwd are never used as identity signals.
    """

    def __init__(self, panes: list[dict[str, Any]] | None = None, session_path: str | Path | None = None):
        self.panes = [p for p in (panes or []) if isinstance(p, dict)]
        self.session_path = Path(session_path) if session_path else Path.home() / ".config" / "herdr" / "session.json"
        self.live_ids = {str(p.get("pane_id") or "") for p in self.panes if p.get("pane_id")}
        self.live_by_id = {str(p.get("pane_id") or ""): p for p in self.panes if p.get("pane_id")}
        self.live_by_tab: dict[str, list[dict[str, Any]]] = {}
        for pane in self.panes:
            tab_id = str(pane.get("tab_id") or "")
            if tab_id:
                self.live_by_tab.setdefault(tab_id, []).append(pane)
        self.session_data = read_json_file(self.session_path)
        self.local_map = self._build_local_id_map()

    @classmethod
    def from_herdr_cli(cls, json_runner: JsonRunner | None = None) -> "HerdrPaneBinding":
        return cls(load_live_panes(json_runner=json_runner))

    def _resolve_public(self, workspace_id: str, tab_suffix: str, pane_suffix: str) -> str:
        expected_tab = f"{workspace_id}:t{tab_suffix}"
        direct = f"{workspace_id}:p{pane_suffix}"
        direct_pane = self.live_by_id.get(direct)
        if direct_pane and str(direct_pane.get("tab_id") or "") == expected_tab:
            return direct
        tab_panes = self.live_by_tab.get(expected_tab) or []
        if len(tab_panes) == 1 and tab_panes[0].get("pane_id"):
            return str(tab_panes[0]["pane_id"])
        if direct_pane:
            return direct
        return ""

    def _build_local_id_map(self) -> dict[str, str]:
        out: dict[str, str] = {}
        data = self.session_data
        if not isinstance(data, dict):
            return out
        for workspace in data.get("workspaces") or []:
            workspace_id = workspace.get("id")
            if not workspace_id:
                continue
            public_tabs = workspace.get("public_tab_numbers") or []
            public_panes = workspace.get("public_pane_numbers") or {}
            for idx, tab in enumerate(workspace.get("tabs") or [], start=1):
                tab_public = public_tabs[idx - 1] if idx - 1 < len(public_tabs) else idx
                tab_suffix = base36(tab_public)
                keys = {str(k) for k in (tab.get("panes") or {}).keys()}
                root = tab.get("root_pane")
                focused = tab.get("focused")
                if root is not None:
                    keys.add(str(root))
                if focused is not None:
                    keys.add(str(focused))
                tab_public_fallback = ""
                for candidate in (focused, root):
                    if candidate is None:
                        continue
                    pane_suffix = base36(public_panes.get(str(candidate), candidate))
                    tab_public_fallback = self._resolve_public(str(workspace_id), tab_suffix, pane_suffix)
                    if tab_public_fallback:
                        break
                for local_id in keys:
                    pane_suffix = base36(public_panes.get(str(local_id), local_id))
                    public_id = self._resolve_public(str(workspace_id), tab_suffix, pane_suffix)
                    if public_id:
                        self._add_aliases(out, str(workspace_id), local_id, pane_suffix, public_id)
                if tab_public_fallback:
                    out[f"{workspace_id}:t{tab_suffix}"] = tab_public_fallback
                    out[f"{workspace_id}:t{idx}"] = tab_public_fallback
                    out[f"{workspace_id}:{idx}"] = tab_public_fallback
        return out

    @staticmethod
    def _add_aliases(out: dict[str, str], workspace_id: str, local_id: str, pane_suffix: str, public_id: str) -> None:
        out[local_id] = public_id
        out[f"p_{local_id}"] = public_id
        out[f"p_{pane_suffix}"] = public_id
        out[f"{workspace_id}:p{local_id}"] = public_id
        out[f"{workspace_id}:p{pane_suffix}"] = public_id

    def normalize(self, pane_id: str | None) -> str:
        pane_id = pane_id or ""
        if pane_id in self.live_ids:
            return pane_id
        return self.local_map.get(pane_id, "")

    def by_session(self, session_id: str | None) -> list[dict[str, Any]]:
        if not session_id:
            return []
        out: list[dict[str, Any]] = []
        for pane in self.panes:
            agent_session = pane.get("agent_session") or {}
            if isinstance(agent_session, dict) and agent_session.get("value") == session_id:
                out.append(pane)
        return out
