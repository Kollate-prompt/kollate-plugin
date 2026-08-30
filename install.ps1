# Kollate for Claude Code - Windows, one command in PowerShell:
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Kollate-prompt/kollate-plugin/main/install.ps1))) https://your-kollate-address
#
# Installs Python automatically if Windows only has the Store stubs. Merges settings.
param([string]$Url)

$ErrorActionPreference = "Stop"
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
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User') + ";$HOME\.local\bin;$env:APPDATA\npm"
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
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User')
  if (Test-Python 'python') { $py = 'python' }
  else { Write-Host "Python installed - close this window, open PowerShell again, rerun the same command."; return }
}

# The marketplace add clones with git, which a fresh Windows does not have.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Host "-> Installing git (one time)"
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install -e --id Git.Git --accept-package-agreements --accept-source-agreements
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
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

Write-Host "-> Adding the Kollate marketplace"
claude plugin marketplace add Kollate-prompt/kollate-plugin 2>$null
if ($LASTEXITCODE -ne 0) { claude plugin marketplace update kollate 2>$null }

Write-Host "-> Installing the plugin"
claude plugin install kollate 2>$null
if ($LASTEXITCODE -ne 0) { claude plugin install kollate@kollate 2>$null }
claude plugin update kollate@kollate 2>$null
if ($LASTEXITCODE -ne 0) { claude plugin update kollate 2>$null }

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
