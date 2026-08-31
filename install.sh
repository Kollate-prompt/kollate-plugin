#!/usr/bin/env bash
# Kollate for Claude Code - one command.
#
#   curl -fsSL https://raw.githubusercontent.com/Kollate-prompt/kollate-plugin/main/install.sh | bash -s -- https://your-kollate-address
#
# Works on every Claude Code version: the address is written to settings.json rather than
# passed as --config, which older builds reject. Existing settings are merged, not replaced.
set -euo pipefail

URL="${1:-}"
if [ -z "$URL" ]; then
  echo "Usage: install.sh https://your-kollate-address" >&2
  echo "Your Kollate address is the one you sign in at - it is shown on the Connect page." >&2
  exit 2
fi
case "$URL" in
  https://*) ;;
  *) echo "The address must start with https:// - got: $URL" >&2; exit 2 ;;
esac

# Claude Code itself is a dependency like any other. Refusing here and telling someone to go
# run a second command is the one step that turns a one-liner back into a support thread.
if ! command -v claude >/dev/null; then
  export PATH="$HOME/.local/bin:$PATH"
fi
if ! command -v claude >/dev/null; then
  echo "→ Installing Claude Code (one time)"
  curl -fsSL https://claude.ai/install.sh | bash
  export PATH="$HOME/.local/bin:$PATH"
fi
command -v claude  >/dev/null || { echo "Claude Code could not be installed - install it from https://claude.ai/download, then rerun this command." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required (macOS and Linux ship it)." >&2; exit 1; }
command -v curl    >/dev/null || { echo "curl is required."               >&2; exit 1; }

KOLLATE_LOG="$HOME/.kollate/install-log.txt"
mkdir -p "$(dirname "$KOLLATE_LOG")" 2>/dev/null || true
# Every claude call is logged with its output and exit code. When something fails we
# want the real message, not a swallowed one - the previous version sent all of it to
# /dev/null, which is why a real failure in the field arrived as a screenshot with no
# way to tell what had actually been declared.
run_claude() {
  local out rc
  out=$("$@" 2>&1); rc=$?
  { echo "\$ $*"; echo "$out"; echo "exit=$rc"; } >> "$KOLLATE_LOG"
  if [ $rc -ne 0 ]; then echo "$out"; fi
  return $rc
}

echo "→ Clearing any previous Kollate marketplace"
python3 - <<'KOLLATE_CLEAN'
import json, os, platform, shutil, sys, time, urllib.parse

NAME = "kollate"
home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
log_path = os.path.join(os.path.expanduser("~/.kollate"), "install-log.txt")
removed = []

def log(line):
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "a") as out:
            out.write(line + "\n")
    except Exception:
        pass

def safe_url(raw):
    """A URL can carry credentials inline (https://user:token@host/path). This log is
    meant to be pasted into a chat, so drop the userinfo before it is ever written."""
    try:
        parts = urllib.parse.urlparse(raw)
        if not parts.hostname:
            return "<redacted>" if "@" in raw else raw
        netloc = parts.hostname + (":%d" % parts.port if parts.port else "")
        return parts._replace(netloc=netloc).geturl()
    except Exception:
        return "<unparseable>"

def redact(value):
    """A marketplace source may carry auth headers, and any URL in it may carry
    credentials. Never write either to a log the user is going to share."""
    if isinstance(value, dict):
        return {k: ("<redacted>" if k.lower() in ("headers", "token", "authorization")
                    else redact(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    if isinstance(value, str) and "://" in value:
        return safe_url(value)
    return value

def load(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except Exception:
        return None

def save(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as out:
        json.dump(data, out, indent=2)
    os.replace(tmp, path)

log("")
log("=== kollate install %s ===" % time.strftime("%Y-%m-%d %H:%M:%S"))
log("os=%s %s  python=%s  config=%s" % (platform.system(), platform.release(),
                                        platform.python_version(), home))

# Record the declaration we are about to remove, VERBATIM. If the add still fails
# after this, that record is the only evidence of what shape was actually there -
# and not knowing that is exactly what has made this hard to diagnose.
settings_path = os.path.join(home, "settings.json")
settings = load(settings_path)
if isinstance(settings, dict):
    known = settings.get("extraKnownMarketplaces")
    if isinstance(known, dict) and NAME in known:
        log("found declaration in settings.json:")
        log(json.dumps(redact(known[NAME]), indent=2))
        known.pop(NAME)
        if not known:
            settings.pop("extraKnownMarketplaces", None)
        save(settings_path, settings)
        removed.append("settings declaration")
    else:
        log("no kollate declaration in settings.json")
else:
    log("settings.json missing or unreadable")

catalog_path = os.path.join(home, "plugins", "known_marketplaces.json")
catalog = load(catalog_path)
if isinstance(catalog, dict) and NAME in catalog:
    log("found catalog entry:")
    log(json.dumps(redact(catalog[NAME]), indent=2))
    catalog.pop(NAME)
    save(catalog_path, catalog)
    removed.append("catalog entry")

clone = os.path.join(home, "plugins", "marketplaces", NAME)
if os.path.isdir(clone):
    try:
        with open(os.path.join(clone, ".git", "config")) as handle:
            for line in handle:
                if "url" in line:
                    # A remote can carry credentials inline (https://user:token@host/...).
                    # This log is meant to be pasted into a chat, so strip userinfo.
                    raw = line.rstrip().split("=", 1)[-1].strip()
                    try:
                        parts = urllib.parse.urlparse(raw)
                        if parts.hostname:
                            netloc = parts.hostname + (":%d" % parts.port if parts.port else "")
                            safe = parts._replace(netloc=netloc).geturl()
                        else:
                            safe = raw if "@" not in raw else "<redacted>"
                    except Exception:
                        safe = "<unparseable>"
                    log("cached clone remote: %s" % safe)
    except Exception:
        log("cached clone present, remote unreadable")
    shutil.rmtree(clone, ignore_errors=True)
    removed.append("cached copy")

log("cleared: %s" % (", ".join(removed) if removed else "nothing - was already clean"))
if removed:
    print("   (cleared a previous Kollate marketplace: " + ", ".join(removed) + ")")
KOLLATE_CLEAN

echo "→ Adding the Kollate marketplace"
if ! run_claude claude plugin marketplace add Kollate-prompt/kollate-plugin; then
  echo "The marketplace could not be added. Full detail: $KOLLATE_LOG" >&2
  echo "Send that file and this can be diagnosed instead of guessed at." >&2
  exit 1
fi

echo "→ Installing the plugin"
run_claude claude plugin install kollate || run_claude claude plugin install kollate@kollate

# `install` is a no-op when the plugin is already present, and an old version is exactly why
# someone re-runs this script - so always finish on the latest release.
claude plugin update kollate@kollate >/dev/null 2>&1 || claude plugin update kollate >/dev/null 2>&1 || true

echo "→ Pointing it at $URL"
KOLLATE_URL="$URL" python3 - <<'PY'
import json, os

path = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
                    "settings.json")
try:
    with open(path) as handle:
        settings = json.load(handle)
except Exception:
    settings = {}

# Merge. Somebody's other plugins, hooks and permissions live in this file too.
options = (settings.setdefault("pluginConfigs", {})
                   .setdefault("kollate@kollate", {})
                   .setdefault("options", {}))
options["endpoint"] = os.environ["KOLLATE_URL"].rstrip("/")
settings.setdefault("enabledPlugins", {})["kollate@kollate"] = True

os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)

# Keep whatever permissions the file already had; create a new one owner-only. This file can
# carry hook commands and permission rules, so it must not become group- or world-writable.
try:
    mode = os.stat(path).st_mode & 0o777
except OSError:
    mode = 0o600

tmp = path + ".tmp"
handle = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(handle, "w") as out:
    json.dump(settings, out, indent=2)
os.chmod(tmp, mode)
os.replace(tmp, path)

# The desktop app loads the plugin but has no userConfig screen - its plugin page offers only
# Skills and Hooks - so the setting above is invisible there. The same address goes to a file
# both surfaces read, which is what lets one install cover the terminal and the app.
shared = os.path.expanduser("~/.kollate")
os.makedirs(shared, mode=0o700, exist_ok=True)
config = os.path.join(shared, "config.json")
tmp = config + ".tmp"
handle = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(handle, "w") as out:
    json.dump({"endpoint": os.environ["KOLLATE_URL"].rstrip("/")}, out)
os.replace(tmp, config)
PY

cat <<DONE

  Installed.

  Two things left, and they are both yours:

    1. Quit Claude Code completely and open it again.
       Plugins load at startup - a session already running will not see this one.

    2. Run:  /kollate:connect

  Your browser opens the sign-in you already use. Approve it, and this machine is
  connected. You are never shown a key and never edit a file.

DONE
