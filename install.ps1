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
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Host "-> Installing Claude Code (one time)"
  irm https://claude.ai/install.ps1 | iex
  Sync-Path
}
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Host "Claude Code could not be installed automatically. Get it from https://claude.ai/download,"
  Write-Host "then open PowerShell again and rerun the same command."
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
import json, os, platform, shutil, sys, time

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

def redact(value):
    """A marketplace source may carry auth headers. Never write those to a log
    the user is going to paste into a chat."""
    if isinstance(value, dict):
        return {k: ("<redacted>" if k.lower() in ("headers", "token", "authorization")
                    else redact(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
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
                    log("cached clone remote:%s" % line.rstrip().split("=", 1)[-1])
    except Exception:
        log("cached clone present, remote unreadable")
    shutil.rmtree(clone, ignore_errors=True)
    removed.append("cached copy")

log("cleared: %s" % (", ".join(removed) if removed else "nothing - was already clean"))
if removed:
    print("   (cleared a previous Kollate marketplace: " + ", ".join(removed) + ")")
'@
$cleancode | & $py -

Write-Host "-> Adding the Kollate marketplace"
if ((Invoke-Claude plugin marketplace add Kollate-prompt/kollate-plugin) -ne 0) {
  Write-Host "The marketplace could not be added. Full detail: $KollateLog"
  Write-Host "Send that file and this can be diagnosed instead of guessed at."
  return
}

Write-Host "-> Installing the plugin"
if ((Invoke-Claude plugin install kollate) -ne 0) { $null = Invoke-Claude plugin install kollate@kollate }
if ((Invoke-Claude plugin update kollate@kollate) -ne 0) { $null = Invoke-Claude plugin update kollate }

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

Write-Host ""
Write-Host "  Installed."
Write-Host ""
Write-Host "  Two things left, and they are both yours:"
Write-Host "    1. Close Claude Code completely and open it again."
Write-Host "    2. Run:  /kollate:connect"
Write-Host ""
