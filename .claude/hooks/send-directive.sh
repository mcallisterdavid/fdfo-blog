#!/usr/bin/env bash
# send-directive.sh — Send a directive from the HQ director to a team lead.
#
# Top-down messaging: director → team lead. Wraps send-to-teammate.sh with
# director conventions (DIRECTIVE prefix, director@hq sender, directive logging).
# No loop guard needed — directives are strictly one-directional.
#
# Usage:
#   bash .claude/hooks/send-directive.sh \
#     --to-team <target> [--priority normal|high] \
#     [--directive-type info|action|question|merge-result] \
#     <message>
#
# Examples:
#   bash .claude/hooks/send-directive.sh --to-team fish-humanoid "Focus on speed metric"
#   bash .claude/hooks/send-directive.sh --to-team fish-humanoid --priority high --directive-type action "Stop all runs immediately"

set -euo pipefail

TO_TEAM=""
PRIORITY="normal"
DIRECTIVE_TYPE="info"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HQ_DIR="$HOME/.claude/hq"
LOG_FILE="${HQ_DIR}/directives-log.jsonl"

usage() {
  echo "Usage: $0 --to-team <target> [--priority normal|high] [--directive-type info|action|question|merge-result] <message>" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to-team)         TO_TEAM="$2"; shift 2 ;;
    --priority)        PRIORITY="$2"; shift 2 ;;
    --directive-type)  DIRECTIVE_TYPE="$2"; shift 2 ;;
    -h|--help)         usage ;;
    -*)                echo "Unknown option: $1" >&2; usage ;;
    *)                 break ;;  # remaining args are the message
  esac
done

if [[ -z "$TO_TEAM" ]]; then
  echo "Error: --to-team is required." >&2
  usage
fi

# Get message from remaining args
if [[ $# -ge 1 ]]; then
  MESSAGE="$*"
else
  read -rp "Directive to team-lead@${TO_TEAM}: " MESSAGE
fi

if [[ -z "$MESSAGE" ]]; then
  echo "No message provided." >&2
  exit 1
fi

# Verify HQ config exists (caller should be director)
HQ_CONFIG="${HQ_DIR}/config.json"
if [[ ! -f "$HQ_CONFIG" ]]; then
  echo "WARNING: HQ config not found at ${HQ_CONFIG}. Director may not be initialized." >&2
fi

# Validate target team exists
TARGET_CONFIG="$HOME/.claude/teams/${TO_TEAM}/config.json"
if [[ ! -f "$TARGET_CONFIG" ]]; then
  echo "WARNING: team '${TO_TEAM}' has no config.json. Message may go unread." >&2
fi

# Construct directive message
PRIORITY_TAG=""
if [[ "$PRIORITY" == "high" ]]; then
  PRIORITY_TAG=" [HIGH]"
fi

TYPE_TAG=""
if [[ "$DIRECTIVE_TYPE" != "info" ]]; then
  TYPE_TAG=" [$(echo "$DIRECTIVE_TYPE" | tr '[:lower:]' '[:upper:]')]"
fi

FULL_MESSAGE="DIRECTIVE${PRIORITY_TAG}${TYPE_TAG}: ${MESSAGE}"

# Send via send-to-teammate.sh
bash "${SCRIPT_DIR}/send-to-teammate.sh" \
  -t "$TO_TEAM" \
  -r "team-lead" \
  -s "director@hq" \
  "$FULL_MESSAGE"

# Log to directives log
mkdir -p "$HQ_DIR"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
PREVIEW="${MESSAGE:0:80}"

python3 -c "
import json, sys, fcntl, time, os

log_file = sys.argv[1]
entry = {
    'timestamp': sys.argv[2],
    'to_team': sys.argv[3],
    'priority': sys.argv[4],
    'directive_type': sys.argv[5],
    'message_preview': sys.argv[6],
}

with open(log_file, 'a') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.write(json.dumps(entry) + '\n')
    fcntl.flock(f, fcntl.LOCK_UN)

# Rate-limit check: count outbound directives in the last hour
one_hour_ago = time.time() - 3600
count = 0
if os.path.isfile(log_file):
    try:
        with open(log_file) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                    from datetime import datetime
                    ts = datetime.fromisoformat(e['timestamp'].replace('Z', '+00:00'))
                    if ts.timestamp() > one_hour_ago:
                        count += 1
                except (json.JSONDecodeError, KeyError, ValueError):
                    continue
    except IOError:
        pass

if count > 5:
    print(f'WARNING: {count} directives sent in the last hour. Consider batching.', file=sys.stderr)
" "$LOG_FILE" "$TIMESTAMP" "$TO_TEAM" "$PRIORITY" "$DIRECTIVE_TYPE" "$PREVIEW"
