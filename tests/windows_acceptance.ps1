# Finds an interpreter the same way the hooks do, then runs the acceptance script.
# `python3` on Windows can be a Store alias stub that exits 0 having done nothing, which is
# why py.exe is asked first - it lives in C:\Windows and is never that stub.
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here 'windows_acceptance.py'

foreach ($try in @(@('py','-3'), @('python3'), @('python'))) {
  $exe = $try[0]; $prefix = @($try | Select-Object -Skip 1)
  if (Get-Command $exe -ErrorAction SilentlyContinue) {
    & $exe @prefix $script
    if ($LASTEXITCODE -ne $null) { exit $LASTEXITCODE }
  }
}
Write-Error 'No Python interpreter found. Look for one before concluding it is missing: where.exe python, then %LOCALAPPDATA%\Programs\Python\Python3*\python.exe'
exit 1
