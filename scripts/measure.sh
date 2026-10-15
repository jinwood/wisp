#!/usr/bin/env bash
# Prints the physical footprint of a running Wisp, the number that matters
# (Activity Monitor's "Memory" column is the same metric).
set -euo pipefail

PID="$(pgrep -x Wisp || true)"
if [[ -z "$PID" ]]; then
  echo "Wisp isn't running" >&2
  exit 1
fi
vmmap --summary "$PID" 2>/dev/null | grep -E "^Physical footprint"
