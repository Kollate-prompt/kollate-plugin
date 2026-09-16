:; d="$(dirname "$0")"; for p in python3 python; do command -v "$p" >/dev/null 2>&1 && exec "$p" -S -E "$d/kollate.py" "$@"; done; for p in "$HOME"/.cache/codex-runtimes/*/dependencies/python/python3 "$HOME"/.cache/codex-runtimes/*/dependencies/python/python; do [ -x "$p" ] && exec "$p" -S -E "$d/kollate.py" "$@"; done; exit 1
@echo off
py -3 -c "import sys" >nul 2>nul && ( py -3 -S -E "%~dp0kollate.py" %* & exit /b )
python -c "import sys" >nul 2>nul && ( python -S -E "%~dp0kollate.py" %* & exit /b )
for /d %%D in ("%USERPROFILE%\.cache\codex-runtimes\*") do if exist "%%~D\dependencies\python\python.exe" ( "%%~D\dependencies\python\python.exe" -S -E "%~dp0kollate.py" %* & exit /b )
exit /b 1
