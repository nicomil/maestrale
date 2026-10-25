#!/bin/zsh
# Summarizes an fs_usage log. Usage: summarize-capture.sh <log> [depth]
set -eu
exec python3 -I "$(dirname "$0")/summarize_capture.py" "$@"
