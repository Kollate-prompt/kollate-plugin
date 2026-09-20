#!/usr/bin/env python3
"""The Claude-profile gate, driven the way the hook and connect drive it. Local only.

A user connects Kollate under the company profile of the desktop app and switches to a
personal profile: nothing from the personal profile may be captured. Runs on every OS.
    python3 tests/profile_gate.py
"""
import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = tempfile.mkdtemp()
HOME = os.path.join(WORK, "home")
os.makedirs(HOME)
os.environ["HOME"] = HOME
os.environ["USERPROFILE"] = HOME
os.environ["APPDATA"] = os.path.join(HOME, "AppData", "Roaming")
os.environ["CLAUDE_PLUGIN_DATA"] = os.path.join(WORK, "data")
os.environ.pop("CLAUDE_CONFIG_DIR", None)
os.environ.pop("CLAUDE_PLUGIN_ROOT", None)

spec = importlib.util.spec_from_file_location("kollate", os.path.join(HERE, "..", "plugins", "kollate", "hooks", "kollate.py"))
k = importlib.util.module_from_spec(spec)
spec.loader.exec_module(k)

COMPANY, PERSONAL, ACCOUNT = "org-company", "org-personal", "acct-1"
results = []


def check(name, expected, got):
    ok = expected == got
    results.append(ok)
    print(f"  {'ok  ' if ok else 'FAIL'} {name:56} {got!r}" + ("" if ok else f"  (expected {expected!r})"))


def write(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle)


def terminal_login(org, email="e@x"):
    write(os.path.join(HOME, ".claude.json"),
          {"oauthAccount": {"organizationUuid": org, "accountUuid": ACCOUNT, "emailAddress": email,
                            "organizationName": org.upper()}})


def desktop_session(org, cli_session_id):
    store = k.desktop_session_stores()[0]
    write(os.path.join(store, ACCOUNT, org, f"local_{cli_session_id}.json"),
          {"sessionId": f"local_{cli_session_id}", "cliSessionId": cli_session_id})


def connected(profile):
    cred = {"capture_token": "t", "hook_secret": "s", "endpoint": "http://e", "api_base": "http://e"}
    if profile:
        cred["claude_profile"] = profile
    write(k.credentials_path(), cred)


print("profile gate")
# 1. Nothing known anywhere: no gate, and no crash.
connected(None)
check("no .claude.json, no store -> unknown profile", {}, k.claude_profile("s0"))
check("unknown live + no stored profile -> captured", "", k.capture_blocked("s0"))

# 2. Terminal: .claude.json is the source.
terminal_login(COMPANY, "boss@corp")
live = k.claude_profile("s1")
check("terminal profile read from .claude.json", ("claude.json", COMPANY, "boss@corp"),
      (live["source"], live["org"], live["email"]))

# 3. Connected under the company profile; the same profile keeps capturing.
connected(live)
check("same profile -> captured", "", k.capture_blocked("s1"))

# 4. Terminal user logs into the personal profile: dropped.
terminal_login(PERSONAL, "me@home")
check("terminal switched to personal -> blocked", "a different Claude profile is signed in", k.capture_blocked("s1"))

# 5. Desktop app: the store beats .claude.json (which the app copies from the terminal login).
desktop_session(COMPANY, "desk-company")
desktop_session(PERSONAL, "desk-personal")
check("desktop store wins over .claude.json", ("desktop", COMPANY), 
      (k.claude_profile("desk-company")["source"], k.claude_profile("desk-company")["org"]))
check("desktop company session -> captured", "", k.capture_blocked("desk-company"))
check("desktop personal session -> blocked", "a different Claude profile is signed in", k.capture_blocked("desk-personal"))

# 6. Identity unreadable at hook time: fail open, never a silent stop for everyone.
os.remove(os.path.join(HOME, ".claude.json"))
check("no live identity -> captured (fail open)", "", k.capture_blocked("s-unknown"))

# 7. CLAUDE_CONFIG_DIR is honoured before ~ .
cfg = os.path.join(WORK, "cfg")
write(os.path.join(cfg, ".claude.json"), {"oauthAccount": {"organizationUuid": PERSONAL, "accountUuid": ACCOUNT}})
os.environ["CLAUDE_CONFIG_DIR"] = cfg
check("CLAUDE_CONFIG_DIR/.claude.json read first", PERSONAL, k.claude_profile("s2").get("org"))
os.environ.pop("CLAUDE_CONFIG_DIR")

# 8. Codex host never gates on Claude profiles.
os.environ["CLAUDE_PLUGIN_ROOT"] = os.path.join(HOME, ".codex", "plugins", "cache", "kollate")
terminal_login(PERSONAL)
check("codex host ignores the gate", "", k.capture_blocked("s3"))
os.environ.pop("CLAUDE_PLUGIN_ROOT")

# 9. Old credential (connected before profiles were recorded): everything captured, as before.
connected(None)
check("legacy credential without profile -> captured", "", k.capture_blocked("desk-personal"))

print(f"\n{sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if all(results) else 1)
