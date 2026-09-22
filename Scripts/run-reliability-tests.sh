#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"
swift test
echo "Reliability suite passed. Fault cases cover launch failure, generation failure, cancellation, interrupted persistence, and restart circuit breaking."
