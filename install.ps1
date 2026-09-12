# Kollate for Claude Code - Windows, one command in PowerShell:
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Kollate-prompt/kollate-plugin/main/install.ps1))) https://your-kollate-address
#
# Installs Python automatically if Windows only has the Store stubs. Merges settings.
param([string]$Url)

$ErrorActionPreference = "Stop"

# Claude Code's own installer drops claude.exe in ~\.local\bin and does NOT add it to the
# user PATH - it prints a note telling the person to do that by hand. So every time this
# script refreshes PATH from the registry it must add those directories back, or a later
# refresh silently un-finds the claude we just installed.
$KollateBins = "$HOME\.local\bin;$env:APPDATA\npm"
function Sync-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User') + ';' + $KollateBins
}
if (-not $Url) { Write-Host "Usage: install.ps1 https://your-kollate-address"; return }
if ($Url -notmatch '^https://') { Write-Host "The address must start with https:// - got: $Url"; return }
$Url = $Url.TrimEnd('/')

# The claude CLI may exist without being on PATH - its native installer drops it in
# ~\.local\bin and tells the person to edit PATH themselves. Hunt before giving up.
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  foreach ($dir in @("$HOME\.local\bin", "$env:APPDATA\npm")) {
    if ((Test-Path (Join-Path $dir 'claude.exe')) -or (Test-Path (Join-Path $dir 'claude.cmd'))) {
      $env:Path += ";$dir"; break
    }
  }
}
# Claude Code itself is a dependency like any other. Refusing here and telling someone to go
# run a second command is the one step that turns a one-liner back into a support thread.
#
# Unless they are here for Codex. Someone who already runs Codex and not Claude Code should not
# have a second agent installed on their machine as a side effect of capturing the one they do
# use, so the bootstrap only fires when neither is present - the same rule install.sh follows.
$hasCodex = [bool](Get-Command codex -ErrorAction SilentlyContinue)
if (-not (Get-Command claude -ErrorAction SilentlyContinue) -and -not $hasCodex) {
  Write-Host "-> Installing Claude Code (one time)"
  irm https://claude.ai/install.ps1 | iex
  Sync-Path
}
if (-not (Get-Command claude -ErrorAction SilentlyContinue) -and -not $hasCodex) {
  Write-Host "Neither Claude Code nor Codex is installed, and Claude Code could not be installed"
  Write-Host "automatically. Get Claude Code from https://claude.ai/download or Codex with"
  Write-Host "'npm i -g @openai/codex', then open PowerShell again and rerun the same command."
  return
}

# Real Python? The Store stub fails on any actual script.
function Test-Python($exe) {
  try { $out = & $exe -c "print('kollate-ok')" 2>$null; return ($out -eq 'kollate-ok') } catch { return $false }
}
$py = $null
foreach ($candidate in @('python', 'python3', 'py')) {
  if (Test-Python $candidate) { $py = $candidate; break }
}
if (-not $py) {
  Write-Host "-> Installing Python (one time)"
  # winget is missing on lean/fresh Windows installs (App Installer not provisioned) -
  # seen on a clean 24H2 ARM64 bench 30.08. Fall back to python.org directly.
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements
  } else {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $pyUrl = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-$arch.exe"
    $pyHash = @{ 'arm64' = '377ac8fd478987940088e879441e702a71b53164d2a1e6f1d51ff77a7e470258'
                 'amd64' = '67b5635e80ea51072b87941312d00ec8927c4db9ba18938f7ad2d27b328b95fb' }[$arch]
    $pyExe = Join-Path $env:TEMP "python-setup.exe"
    Write-Host "   (no winget here - downloading from python.org)"
    Invoke-WebRequest -Uri $pyUrl -OutFile $pyExe
    if ((Get-FileHash $pyExe -Algorithm SHA256).Hash -ne $pyHash) {
      Write-Host "Download integrity check FAILED for Python - stopping. Rerun, and if it repeats, tell your admin."
      Remove-Item $pyExe -ErrorAction SilentlyContinue; return
    }
    Start-Process -Wait $pyExe -ArgumentList '/quiet','InstallAllUsers=0','PrependPath=1','Include_launcher=1'
    Remove-Item $pyExe -ErrorAction SilentlyContinue
  }
  # Pick up the new PATH without a new window
  Sync-Path
  if (Test-Python 'python') { $py = 'python' }
  else { Write-Host "Python installed - close this window, open PowerShell again, rerun the same command."; return }
}

# The marketplace add clones with git, which a fresh Windows does not have.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Host "-> Installing git (one time)"
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install -e --id Git.Git --accept-package-agreements --accept-source-agreements
    Sync-Path
  } else {
    $garch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { '64-bit' }
    $gitUrl = "https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.5/MinGit-2.55.0.5-$garch.zip"
    $gitHash = @{ 'arm64' = '05843f9d6e60306c3ab886799e2c67200caab921571f10512df3493049179ddb'
                  '64-bit' = '56d7b226b7693196cfc71fef26568f536c4a021ab6c37ff2db4287bed908e96e' }[$garch]
    $gitZip = Join-Path $env:TEMP 'mingit.zip'
    $gitDir = Join-Path $env:LOCALAPPDATA 'Programs\MinGit'
    Write-Host "   (no winget here - downloading MinGit)"
    Invoke-WebRequest -Uri $gitUrl -OutFile $gitZip
    if ((Get-FileHash $gitZip -Algorithm SHA256).Hash -ne $gitHash) {
      Write-Host "Download integrity check FAILED for git - stopping. Rerun, and if it repeats, tell your admin."
      Remove-Item $gitZip -ErrorAction SilentlyContinue; return
    }
    Expand-Archive -Path $gitZip -DestinationPath $gitDir -Force
    Remove-Item $gitZip -ErrorAction SilentlyContinue
    $gitBin = Join-Path $gitDir 'cmd'
    $env:Path += ";$gitBin"
    $userPath = [Environment]::GetEnvironmentVariable('Path','User')
    if ($userPath -notlike "*MinGit*") {
      [Environment]::SetEnvironmentVariable('Path', "$userPath;$gitBin", 'User')
    }
  }
}

$KollateLog = Join-Path $HOME ".kollate\install-log.txt"
New-Item -ItemType Directory -Force -Path (Split-Path $KollateLog) | Out-Null
# `claude` writes to stderr on failure. With $ErrorActionPreference = "Stop" that is a
# TERMINATING error, so the script used to abort here and never install anything - the
# user just saw a red NativeCommandError. Capture the stream instead of dying on it,
# and log every call with its exit code.
function Invoke-Claude {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $out = & claude @args 2>&1 | Out-String
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  Add-Content -Path $KollateLog -Value ("$ claude " + ($args -join ' ') + "`n" + $out + "exit=$code")
  if ($code -ne 0) { Write-Host $out }
  return $code
}

Write-Host "-> Clearing any previous Kollate marketplace"
$cleancode = @'
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
'@
$cleancode | & $py -

# Every step from here to the Codex section speaks to the `claude` CLI. On a machine that only
# runs Codex there is nothing for them to talk to, and failing here used to `return` before the
# Codex install was ever reached - so a Codex-only Windows user got nothing at all.
if (Get-Command claude -ErrorAction SilentlyContinue) {
  Write-Host "-> Adding the Kollate marketplace"
  if ((Invoke-Claude plugin marketplace add Kollate-prompt/kollate-plugin) -ne 0) {
    Write-Host "The marketplace could not be added. Full detail: $KollateLog"
    Write-Host "Send that file and this can be diagnosed instead of guessed at."
    return
  }

  Write-Host "-> Installing the plugin"
  if ((Invoke-Claude plugin install kollate) -ne 0) { $null = Invoke-Claude plugin install kollate@kollate }
  if ((Invoke-Claude plugin update kollate@kollate) -ne 0) { $null = Invoke-Claude plugin update kollate }
}

Write-Host "-> Pointing it at $Url"
$env:KOLLATE_URL = $Url
$pycode = @'
import json, os

path = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
                    "settings.json")
try:
    with open(path) as handle:
        settings = json.load(handle)
except Exception:
    settings = {}

options = (settings.setdefault("pluginConfigs", {})
                   .setdefault("kollate@kollate", {})
                   .setdefault("options", {}))
options["endpoint"] = os.environ["KOLLATE_URL"]
settings.setdefault("enabledPlugins", {})["kollate@kollate"] = True

os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w") as out:
    json.dump(settings, out, indent=2)
os.replace(tmp, path)

shared = os.path.expanduser("~/.kollate")
os.makedirs(shared, exist_ok=True)
with open(os.path.join(shared, "config.json"), "w") as out:
    json.dump({"endpoint": os.environ["KOLLATE_URL"]}, out)
'@
$pycode | & $py -


# ------------------------------------------------------------------------------------ Codex
# Codex keeps its own marketplace and its own copy of the manifests in this same repository,
# so installing there is two commands rather than surgery on anybody's hooks.json.
#
# One thing differs on Windows and has to be repaired here. Codex runs a hook command through
# a shell on macOS and Linux, and NOT on Windows: the `A || B || C` interpreter probe that the
# POSIX manifest relies on is never executed here, and Codex reports the hook as Failed. The
# Windows manifest is therefore a single `py -3` invocation with no shell operators, and this
# is where the installed copy gets pointed at it. Rerun this installer after
# `codex plugin marketplace upgrade` - an upgrade restores the plugin's own manifest choice.
#
# Which copy, though, is not ours to predict. 0.152 ran the plugin out of
# `plugins\cache\kollate\kollate\<version>`; 0.154 runs it out of
# `.tmp\marketplaces\kollate\plugins\kollate`, and patching only the first left Windows
# loading the POSIX manifest and capturing nothing, silently - the exact failure this file
# exists to prevent, reintroduced by a version bump. So every copy under CODEX_HOME is
# repointed, and the count is asserted rather than assumed: zero means Codex has moved the
# plugin again and the person needs to hear so, not be told "Installed".
$codexInstalled = $false
if (Get-Command codex -ErrorAction SilentlyContinue) {
  Write-Host "-> Codex found - installing there too"
  # Adding a marketplace that is already configured is not an error worth stopping for.
  & codex plugin marketplace add https://github.com/Kollate-prompt/kollate-plugin 2>&1 | Out-Null
  & codex plugin marketplace upgrade kollate 2>&1 | Out-Null
  & codex plugin add kollate@kollate 2>&1 | Out-Null
  $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "$HOME\.codex" }
  $manifests = @(Get-ChildItem $codexHome -Recurse -Force -Filter 'plugin.json' -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -like '*\.codex-plugin' -and $_.FullName -like '*kollate*' })
  $repointed = 0
  foreach ($m in $manifests) {
    try {
      $spec = Get-Content $m.FullName -Raw | ConvertFrom-Json
      if ($spec.name -ne 'kollate') { continue }
      $spec.hooks = './hooks/hooks-codex-windows.json'
      # Not Set-Content -Encoding UTF8: on Windows PowerShell 5.1 that writes a BOM, and a
      # plugin.json beginning EF BB BF is not JSON as far as Codex is concerned. It drops the
      # plugin's hooks and says nothing, which looks exactly like a working install.
      [System.IO.File]::WriteAllText($m.FullName, ($spec | ConvertTo-Json -Depth 20),
                                     (New-Object System.Text.UTF8Encoding $false))
      $repointed++
    } catch { }
  }
  # `codex plugin add` caches each version in its own directory and leaves the previous ones
  # behind. Codex indexes skills out of all of them, so an upgraded machine keeps offering
  # commands from a version that is gone - seen as "that linked 0.4.44 status skill is missing
  # locally" on an 0.4.48 install (12.09). Keep only the newest.
  $cache = Join-Path $codexHome 'plugins\cache\kollate\kollate'
  if (Test-Path $cache) {
    $versions = @(Get-ChildItem $cache -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^\d+(\.\d+)*$' } |
      Sort-Object { [version]($_.Name) })
    if ($versions.Count -gt 1) {
      foreach ($stale in $versions[0..($versions.Count - 2)]) {
        Remove-Item $stale.FullName -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }

  if ($repointed -gt 0) {
    $codexInstalled = $true
    $writable = @'
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
'@
    $writable | & $py -
  } else {
    Write-Host "   Codex is installed, but Kollate's manifest was not found where Codex keeps it," -ForegroundColor Yellow
    Write-Host "   so hooks would silently never run. Nothing is being captured from Codex." -ForegroundColor Yellow
  }
}

Write-Host ""
Write-Host "  Installed."
Write-Host ""
# Someone here for Codex alone should not be told to restart a program they do not have.
if (Get-Command claude -ErrorAction SilentlyContinue) {
  Write-Host "  Two things left, and they are both yours:"
  Write-Host "    1. Close Claude Code completely and open it again."
  Write-Host "    2. Run:  /kollate:connect"
  Write-Host ""
}
if ($codexInstalled) {
  Write-Host "  In Codex, three things:"
  Write-Host "    1. Quit Codex completely and open it again."
  Write-Host "    2. Run /hooks and press t to trust Kollate's - Codex runs no hook you"
  Write-Host "       have not approved, and says nothing when it skips one."
  Write-Host "    3. Run:  kollate:connect"
  Write-Host ""
}
