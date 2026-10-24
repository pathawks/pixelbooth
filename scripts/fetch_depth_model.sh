#!/bin/zsh
# Select and prepare one pinned local-inference model before app assembly.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/configure_cli_developer_dir.sh
python3 scripts/depth_model.py "$@"
