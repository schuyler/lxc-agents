#!/bin/bash
set -euo pipefail

dir=/home/claude/${1:-code}
shift || true

exec lxc exec claude-code --user 1000 --group 1000 --cwd "$dir" -- claude "$@"
