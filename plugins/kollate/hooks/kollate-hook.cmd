#!/bin/sh
: ; command -v python3 >/dev/null 2>&1 && exec python3 -S -E "$(dirname "$0")/kollate.py" "$@"; exec python -S -E "$(dirname "$0")/kollate.py" "$@"
@py -3 -S -E "%~dp0kollate.py" %* || @python -S -E "%~dp0kollate.py" %*
