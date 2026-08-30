#!/usr/bin/env python3
"""Kollate status line - the always-visible answer to "am I being recorded?".

Installed into ~/.kollate/ and wired into ~/.claude/settings.json by /kollate:connect,
and ONLY when no status line exists there already - somebody's own status line is
never overridden. Local reads only; runs every few seconds, so it must stay instant.
"""
import json
import os
import sys
import time

# Windows consoles default to legacy codepages (cp1252, cp1255...) that cannot encode the
# Kollate mark - found on the Windows bench 30.08 when every print crashed with
# UnicodeEncodeError. Output is ours to define: UTF-8, replacing what a stream can't take.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

KOLLATE = os.path.expanduser("~/.kollate")


def read(name):
    try:
        with open(os.path.join(KOLLATE, name), encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return {}


try:
    event = json.load(sys.stdin)
except Exception:
    event = {}
cwd = ((event.get("workspace") or {}).get("current_dir")) or event.get("cwd") or os.getcwd()
sid = str(event.get("session_id") or "")

LIME, YEL, RED, BLD, DIM, RST = ("\033[38;2;204;240;63m", "\033[33m", "\033[31m",
                                 "\033[1m", "\033[2m", "\033[0m")

if not read("credentials.json").get("capture_token"):
    print(f"{BLD}{RED}✕{RST} {RED}Kollate: not connected{RST} {DIM}/kollate:connect{RST}")
    sys.exit(0)

pause = read("pause.json")
state = ""
if sid and sid in (pause.get("sessions") or []):
    state = "paused for this session"
elif "until" in pause:
    if pause["until"] is None:
        state = "stopped"
    else:
        try:
            if time.time() < float(pause["until"]):
                state = "paused"
        except (TypeError, ValueError):
            pass


def excluded(path):
    dirs = read("consent.json").get("dirs") or {}
    path = os.path.realpath(path)
    while True:
        entry = dirs.get(path)
        if entry and entry.get("excluded"):
            return True
        parent = os.path.dirname(path)
        if parent == path:
            return False
        path = parent


if state:
    print(f"{BLD}{YEL}✕{RST} {YEL}Kollate: {state}{RST} {DIM}/kollate:resume{RST}")
elif excluded(cwd):
    print(f"{BLD}{YEL}✕{RST} {YEL}Kollate: this directory is opted out{RST} {DIM}/kollate:record re-includes it{RST}")
else:
    print(f"{BLD}{LIME}✕ REC{RST} {DIM}→ Kollate · /kollate:pause{RST}")
