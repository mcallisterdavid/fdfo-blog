#!/usr/bin/env bash
# ticker.sh — Background loop that periodically sends POLL_TRIGGER to a teammate.
#
# Usage:
#   bash .claude/hooks/ticker.sh -t <team> [-r <recipient>] [-i <seconds>]
#
# Options:
#   -t, --team        Team name (required)
#   -r, --recipient   Recipient teammate name (default: report-writer)
#   -i, --interval    Seconds between ticks (default: 300)
#
# Launch from the lead agent:
#   Bash(command="bash .claude/hooks/ticker.sh -t my-team > /tmp/claude/ticker.log 2>&1",
#        run_in_background=true)
#
# Stop: kill the background process or send SIGTERM.

set -euo pipefail

TEAM=""
RECIPIENT="report-writer"
INTERVAL=300
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 -t <team> [-r <recipient>] [-i <seconds>]" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "  -t, --team        Team name (required)" >&2
  echo "  -r, --recipient   Recipient (default: report-writer)" >&2
  echo "  -i, --interval    Seconds between ticks (default: 300)" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--team)      TEAM="$2"; shift 2 ;;
    -r|--recipient) RECIPIENT="$2"; shift 2 ;;
    -i|--interval)  INTERVAL="$2"; shift 2 ;;
    -h|--help)      usage ;;
    -*)             echo "Unknown option: $1" >&2; usage ;;
    *)              echo "Unexpected argument: $1" >&2; usage ;;
  esac
done

if [[ -z "$TEAM" ]]; then
  echo "Error: --team is required." >&2
  usage
fi

# Clean exit on SIGTERM/SIGINT
RUNNING=true
cleanup() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Ticker stopped (signal received)."
  RUNNING=false
}
trap cleanup SIGTERM SIGINT

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Ticker started: team=${TEAM}, recipient=${RECIPIENT}, interval=${INTERVAL}s"

while $RUNNING; do
  sleep "$INTERVAL" &
  wait $! || true  # interruptible by trap
  if $RUNNING; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sending POLL_TRIGGER to ${RECIPIENT}"
    bash "${SCRIPT_DIR}/send-to-teammate.sh" -t "$TEAM" -r "$RECIPIENT" -s ticker "POLL_TRIGGER" || \
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARNING: send-to-teammate.sh failed (exit $?)"
  fi
done
