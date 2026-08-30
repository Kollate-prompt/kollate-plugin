# Kollate for Claude Code - Windows, one command in PowerShell:
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Kollate-prompt/kollate-plugin/main/install.ps1))) https://your-kollate-address
#
# Installs Python automatically if Windows only has the Store stubs. Merges settings.
param([string]$Url)

$ErrorActionPreference = "Stop"
if (-not $Url) { Write-Host "Usage: install.ps1 https://your-kollate-address"; exit 2 }
if ($Url -notmatch '^https://') { Write-Host "The address must start with https:// - got: $Url"; exit 2 }
$Url = $Url.TrimEnd('/')

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Host "Claude Code is not installed. Install it first, then rerun this command."; exit 1
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
    $pyExe = Join-Path $env:TEMP "python-setup.exe"
    Write-Host "   (no winget here - downloading from python.org)"
    Invoke-WebRequest -Uri $pyUrl -OutFile $pyExe
    Start-Process -Wait $pyExe -ArgumentList '/quiet','InstallAllUsers=0','PrependPath=1','Include_launcher=1'
    Remove-Item $pyExe -ErrorAction SilentlyContinue
  }
  # Pick up the new PATH without a new window
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User')
  if (Test-Python 'python') { $py = 'python' }
  else { Write-Host "Python installed - close this window, open PowerShell again, rerun the same command."; exit 1 }
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
