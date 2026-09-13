#!/usr/bin/env bash
# Kollate for Claude Code and Codex - one command.
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
#
# Unless they are here for Codex. Someone who already runs Codex and not Claude Code should
# not have a second agent installed on their machine as a side effect of capturing the one
# they do use, so the bootstrap only fires when neither is present.
if ! command -v claude >/dev/null || ! command -v codex >/dev/null; then
  export PATH="$HOME/.local/bin:$PATH"
fi
if ! command -v claude >/dev/null && ! command -v codex >/dev/null; then
  echo "→ Installing Claude Code (one time)"
  curl -fsSL https://claude.ai/install.sh | bash
  export PATH="$HOME/.local/bin:$PATH"
fi
if ! command -v claude >/dev/null && ! command -v codex >/dev/null; then
  echo "Neither Claude Code nor Codex is installed, and Claude Code could not be installed" >&2
  echo "automatically. Install one from https://claude.ai/download or with" >&2
  echo "'npm i -g @openai/codex', then rerun this command." >&2
  exit 1
fi
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

if command -v claude >/dev/null; then
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
KOLLATE_URL="$URL" python3 - <<'KOLLATE_SETTINGS'
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
KOLLATE_SETTINGS

fi  # end of the Claude Code half

# The desktop app loads the plugin but has no userConfig screen - its plugin page offers only
# Skills and Hooks - so the setting above is invisible there. Codex has no userConfig screen
# at all. The same address goes to a file every surface reads, which is what lets one install
# cover the terminal, the app and Codex.
KOLLATE_URL="$URL" python3 - <<'KOLLATE_SHARED'
import json, os

shared = os.path.expanduser("~/.kollate")
os.makedirs(shared, mode=0o700, exist_ok=True)
config = os.path.join(shared, "config.json")
tmp = config + ".tmp"
handle = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(handle, "w") as out:
    json.dump({"endpoint": os.environ["KOLLATE_URL"].rstrip("/")}, out)
os.replace(tmp, config)
KOLLATE_SHARED

# ------------------------------------------------------------------------------------ Codex
# Codex has its own marketplace, its own plugin store and its own copy of the manifests in
# this same repository, so this is two commands rather than surgery on anybody's hooks.json.
CODEX_INSTALLED=""
if command -v codex >/dev/null; then
  echo "→ Codex found - installing there too"
  # Adding a marketplace that is already configured is not an error worth stopping for.
  codex plugin marketplace add https://github.com/Kollate-prompt/kollate-plugin >>"$KOLLATE_LOG" 2>&1 || true
  codex plugin marketplace upgrade kollate >>"$KOLLATE_LOG" 2>&1 || true
  if codex plugin add kollate@kollate >>"$KOLLATE_LOG" 2>&1; then
    CODEX_INSTALLED="yes"
    # The shipped hooks file has to serve a plugin-screen install on either system, so it
    # carries both interpreters and lets the wrong one fail visibly. Nobody who ran this
    # script needs to see that: point the installed copy at the POSIX-only file, exactly as
    # install.ps1 points a Windows install at its own. `marketplace upgrade` undoes this,
    # which is why rerunning this command is the documented repair.
    python3 - <<'KOLLATE_POSIX_HOOKS' >>"$KOLLATE_LOG" 2>&1 || true
import json, os

# os.walk, not glob("**"): glob skips hidden directories, and the copy Codex actually loads
# lives under ~/.codex/.tmp/marketplaces/. The first version of this used glob and repointed
# only the cache copy - the live one kept the two-interpreter file (Gal's Mac, 13.09).
home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
manifests = []
for root, dirs, files in os.walk(home):
    if os.path.basename(root) == ".codex-plugin" and "plugin.json" in files and "kollate" in root:
        manifests.append(os.path.join(root, "plugin.json"))
for manifest in manifests:
    with open(manifest, encoding="utf-8") as handle:
        spec = json.load(handle)
    if spec.get("hooks") == "./hooks/hooks-codex-posix.json":
        continue
    spec["hooks"] = "./hooks/hooks-codex-posix.json"
    with open(manifest, "w", encoding="utf-8") as handle:
        json.dump(spec, handle, indent=2)
KOLLATE_POSIX_HOOKS
    # `codex plugin add` caches each version in its own directory and leaves the previous ones
    # behind. Codex indexes skills out of all of them, so an upgraded machine keeps offering
    # commands from a version that is gone - Eyal hit "that linked 0.4.44 status skill is
    # missing locally" on 0.4.48 (12.09). Keep only the newest.
    python3 - <<'KOLLATE_PRUNE' >>"$KOLLATE_LOG" 2>&1 || true
import os, shutil

home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
cache = os.path.join(home, "plugins", "cache", "kollate", "kollate")


def as_version(name):
    try:
        return tuple(int(part) for part in name.split("."))
    except ValueError:
        return ()


try:
    versions = [n for n in os.listdir(cache) if as_version(n)]
except OSError:
    versions = []
for stale in sorted(versions, key=as_version)[:-1]:
    shutil.rmtree(os.path.join(cache, stale), ignore_errors=True)
    print("pruned stale plugin cache: " + stale)
KOLLATE_PRUNE
    python3 - <<'KOLLATE_WRITABLE' >>"$KOLLATE_LOG" 2>&1 || true
import os, re, shutil, sys

# Codex runs a skill's shell command inside a sandbox, and everything Kollate's commands
# change lives outside the project. Without this, `kollate:pause` is refused and a person
# cannot stop capture from inside Codex - the one promise that must never fail.
home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
path = os.path.join(home, "config.toml")
# A TOML *basic* string treats a backslash as an escape, so a Windows path written that
# way ("C:\\Users\\GT\\.kollate") makes the whole config unparseable and takes Codex
# down with it. TOML literal strings, in single quotes, have no escapes at all.
want = os.path.normpath(os.path.expanduser("~/.kollate"))

quoted = "'" + want + "'"
text = ""
if os.path.isfile(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()

section = re.search(r'(?m)^\[sandbox_workspace_write\]\s*$', text)
if section is None:
    addition = f'\n[sandbox_workspace_write]\nwritable_roots = [{quoted}]\n'
    new = (text.rstrip("\n") + "\n" if text.strip() else "") + addition
elif want in text:
    sys.exit(0)                                   # already allowed - leave the file alone
else:
    start = section.end()
    body = text[start:]
    roots = re.search(r'(?m)^writable_roots\s*=\s*\[', body)
    if roots is None:
        new = text[:start] + f'\nwritable_roots = [{quoted}]' + body
    else:
        at = start + roots.end()
        new = text[:at] + f'{quoted}, ' + text[at:]

if os.path.isfile(path):
    shutil.copyfile(path, path + ".kollate-backup")
os.makedirs(home, exist_ok=True)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(new)
KOLLATE_WRITABLE
  else
    echo "   Codex is installed but the plugin could not be added. Detail: $KOLLATE_LOG" >&2
  fi
fi

echo
echo "  Installed."

if command -v claude >/dev/null; then
cat <<DONE

  In Claude Code, two things left, and they are both yours:

    1. Quit Claude Code completely and open it again.
       Plugins load at startup - a session already running will not see this one.

    2. Run:  /kollate:connect

  Your browser opens the sign-in you already use. Approve it, and this machine is
  connected. You are never shown a key and never edit a file.

DONE
fi

if [ -n "$CODEX_INSTALLED" ]; then
cat <<CODEX_DONE
  In Codex there is one extra step, and nothing is captured until you do it:

    1. Start Codex. It will say some hooks need review.
    2. Trust Kollate's. (Or run /hooks at any time and trust them there.)
    3. Then:  kollate:connect

  Codex will not run a hook it has not been shown, and it says nothing when it skips one -
  so an unapproved install looks exactly like a working one. kollate:status will tell you
  whether the hooks have ever actually run.

CODEX_DONE
fi
