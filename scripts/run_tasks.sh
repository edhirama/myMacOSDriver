#!/bin/bash
# Runs the example tasks through the driver, one after another.
#
#   scripts/run_tasks.sh                 # all five
#   scripts/run_tasks.sh 2 5             # only tasks 2 and 5
#   scripts/run_tasks.sh --dry-run 1 3   # stop before anything changes in your accounts
#
#   scripts/run_tasks.sh --swift 2 5     # the Swift versions (build/drivertasks) instead of the Python ones
#
# Options before the task numbers are passed to every task (--dry-run, --close, --browser NAME).
# MacDriver.app must be running: open build/MacDriver.app
set -uo pipefail
cd "$(dirname "$0")/.."

if ! build/driverctl status >/dev/null 2>&1; then
    echo "MacDriver is not running. Start it with: open build/MacDriver.app" >&2
    exit 2
fi

options=()
swift=0
while [[ $# -gt 0 && "$1" == --* ]]; do
    if [[ "$1" == "--swift" ]]; then swift=1; shift; continue; fi
    options+=("$1")
    case "$1" in --browser|--search|--reply|--max-minutes|--count|--title|--hour|--minutes) options+=("$2"); shift;; esac
    shift
done
if [[ $swift -eq 1 ]]; then
    if [[ ! -x build/drivertasks ]]; then echo "build/drivertasks is missing. Build it with: scripts/bundle.sh" >&2; exit 2; fi
    exec build/drivertasks ${options[@]+"${options[@]}"} "$@"
fi
tasks=("$@")
[[ ${#tasks[@]} -eq 0 ]] && tasks=(1 2 3 4 5)

failed=0
for n in "${tasks[@]}"; do
    script=$(ls examples/tasks/task"${n}"_*.py 2>/dev/null | head -1)
    if [[ -z "$script" ]]; then echo "No task $n" >&2; failed=1; continue; fi
    echo "=== Task $n: $(basename "$script" .py) ==="
    python3 "$script" ${options[@]+"${options[@]}"} || failed=1
    echo
done
exit $failed
