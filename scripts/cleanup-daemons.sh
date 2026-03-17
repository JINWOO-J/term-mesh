#!/bin/bash
# cleanup-daemons.sh — Find and clean orphaned term-meshd processes and stale sockets.
#
# Usage:
#   ./scripts/cleanup-daemons.sh          # dry-run (report only)
#   ./scripts/cleanup-daemons.sh --kill   # kill orphans and remove stale sockets
#   ./scripts/cleanup-daemons.sh --all    # kill ALL term-meshd processes

set -euo pipefail

KILL=false
ALL=false

for arg in "$@"; do
  case "$arg" in
    --kill) KILL=true ;;
    --all) ALL=true; KILL=true ;;
  esac
done

echo "=== Running term-meshd processes ==="
ps -eo pid,lstart,command | grep '[t]erm-meshd' || echo "(none)"
echo ""

if $ALL; then
  echo "=== Killing ALL term-meshd processes ==="
  pkill -f term-meshd 2>/dev/null && echo "killed" || echo "(none running)"
  echo ""
fi

echo "=== Daemon sockets ==="
SOCKETS=()
# Standard locations
for pattern in /tmp/term-meshd*.sock "$HOME/Library/Application Support/term-mesh/term-meshd"*.sock; do
  # shellcheck disable=SC2086
  for sock in $pattern; do
    [ -S "$sock" ] 2>/dev/null && SOCKETS+=("$sock") || true
  done
done

STALE_COUNT=0
if [ ${#SOCKETS[@]} -gt 0 ]; then
  for sock in "${SOCKETS[@]}"; do
    PID=$(lsof -t "$sock" 2>/dev/null || true)
    if [ -z "$PID" ]; then
      echo "  STALE: $sock (no process)"
      STALE_COUNT=$((STALE_COUNT + 1))
      if $KILL; then
        rm -f "$sock"
        echo "    → removed"
      fi
    else
      echo "  ACTIVE: $sock (pid: $PID)"
      if $ALL; then
        kill "$PID" 2>/dev/null || true
        rm -f "$sock"
        echo "    → killed and removed"
      fi
    fi
  done
  if [ "$STALE_COUNT" -eq 0 ]; then
    echo "  (all sockets are active)"
  fi
else
  echo "  (no sockets found)"
fi
echo ""

echo "=== Tag data directories ==="
TAG_DIRS=0
for dir in /tmp/term-mesh-*/; do
  [ -d "$dir" ] 2>/dev/null || continue
  AGE=$(( ( $(date +%s) - $(stat -f %m "$dir") ) / 86400 ))
  echo "  $dir (${AGE}d old)"
  TAG_DIRS=$((TAG_DIRS + 1))
  if $KILL && [ "$AGE" -gt 7 ]; then
    rm -rf "$dir"
    echo "    → removed (older than 7 days)"
  fi
done
[ "$TAG_DIRS" -eq 0 ] && echo "  (none)"
echo ""

echo "=== Daemon log files ==="
for log in /tmp/term-meshd*.log; do
  [ -f "$log" ] 2>/dev/null || continue
  SIZE=$(du -h "$log" | cut -f1)
  echo "  $log ($SIZE)"
done
echo ""

if ! $KILL; then
  echo "Dry run — use --kill to clean stale sockets and old tag dirs, or --all to kill everything."
fi
