#!/usr/bin/env python3
import json
import os
import subprocess
import sys

herdr = os.environ.get("HERDR_BIN_PATH") or "herdr"
workspace = os.environ.get("HERDR_ACTIVE_WORKSPACE_ID")
active_tab = os.environ.get("HERDR_ACTIVE_TAB_ID")

cmd = [herdr, "tab", "list"]
if workspace:
    cmd += ["--workspace", workspace]
try:
    raw = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
    tabs = json.loads(raw).get("result", {}).get("tabs", [])
except Exception:
    sys.exit(0)

if not tabs:
    sys.exit(0)

def tab_num(tab):
    return tab.get("number") or 0

tabs = sorted(tabs, key=tab_num)
idx = next((i for i, tab in enumerate(tabs) if tab.get("tab_id") == active_tab or tab.get("focused")), 0)
next_tab = tabs[(idx + 1) % len(tabs)].get("tab_id")
if next_tab:
    subprocess.DEVNULL
    subprocess.Popen([herdr, "tab", "focus", next_tab], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
