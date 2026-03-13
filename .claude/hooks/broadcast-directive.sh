#!/usr/bin/env bash
# broadcast-directive.sh — Broadcast a directive from the HQ director to all active team leads.
#
# Wraps send-directive.sh, calling it once per active team. Auto-discovers
# active teams from ~/.claude/teams/*/config.json (24h mtime threshold).
#
# Usage:
#   bash .claude/hooks/broadcast-directive.sh \
#     [--only <t1,t2,...>] [--priority normal|high] \
#     [--directive-type info|action|question] \
#     <message>
#
# Examples:
#   bash .claude/hooks/broadcast-directive.sh "New baseline committed to fish"
#   bash .claude/hooks/broadcast-directive.sh --priority high --directive-type action "Stop all runs"
#   bash .claude/hooks/broadcast-directive.sh --only "fish-humanoid,fish-g1" "Share reward weights"

set -euo pipefail

ONLY=""
PRIORITY="normal"
DIRECTIVE_TYPE="info"
STALE_THRESHOLD=86400  # 24 hours
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 [--only <t1,t2,...>] [--priority normal|high] [--directive-type info|action|question] <message>" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)           ONLY="$2"; shift 2 ;;
    --priority)       PRIORITY="$2"; shift 2 ;;
    --directive-type) DIRECTIVE_TYPE="$2"; shift 2 ;;
    -h|--help)        usage ;;
    -*)               echo "Unknown option: $1" >&2; usage ;;
    *)                break ;;  # remaining args are the message
  esac
done

# Get message from remaining args
if [[ $# -ge 1 ]]; then
  MESSAGE="$*"
else
  read -rp "Broadcast directive: " MESSAGE
fi

if [[ -z "$MESSAGE" ]]; then
  echo "No message provided." >&2
  exit 1
fi

TEAMS_DIR="$HOME/.claude/teams"

# Determine the director's own team name (to skip in broadcast)
HQ_DIR="$HOME/.claude/hq"
HQ_TEAM="hq"
if [[ -f "${HQ_DIR}/config.json" ]]; then
  HQ_TEAM=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get('team_name', 'hq'))
except:
    print('hq')
" "${HQ_DIR}/config.json" 2>/dev/null || echo "hq")
fi

# Build target list
declare -a TARGETS=()

if [[ -n "$ONLY" ]]; then
  IFS=',' read -ra TARGETS <<< "$ONLY"
else
  # Auto-discover active teams
  if [[ ! -d "$TEAMS_DIR" ]]; then
    echo "No teams directory found." >&2
    exit 0
  fi

  NOW=$(date +%s)
  for config_path in "$TEAMS_DIR"/*/config.json; do
    [[ -f "$config_path" ]] || continue
    team_dir=$(dirname "$config_path")
    team_name=$(basename "$team_dir")

    # Skip director's own team
    [[ "$team_name" == "$HQ_TEAM" ]] && continue

    # Check mtime for liveness
    MTIME=$(stat -c %Y "$config_path" 2>/dev/null || stat -f %m "$config_path" 2>/dev/null)
    AGE=$(( NOW - MTIME ))
    if [[ $AGE -lt $STALE_THRESHOLD ]]; then
      TARGETS+=("$team_name")
    fi
  done
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No target teams found for broadcast." >&2
  exit 0
fi

# Send to each target
echo "Broadcasting directive to ${#TARGETS[@]} team(s):"
SENT=0
FAILED=0

for target in "${TARGETS[@]}"; do
  # Skip director's own team
  [[ "$target" == "$HQ_TEAM" ]] && continue

  if bash "${SCRIPT_DIR}/send-directive.sh" \
    --to-team "$target" \
    --priority "$PRIORITY" \
    --directive-type "$DIRECTIVE_TYPE" \
    "$MESSAGE"; then
    SENT=$((SENT + 1))
  else
    echo "  FAILED: $target" >&2
    FAILED=$((FAILED + 1))
  fi
done

echo "Broadcast complete: ${SENT} sent, ${FAILED} failed."
