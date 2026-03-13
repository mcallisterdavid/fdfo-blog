#!/usr/bin/env bash
# send-to-teammate.sh — Send a message to a Claude Code teammate via its inbox file.
#
# Usage:
#   bash .claude/hooks/send-to-teammate.sh -t <team> -r <recipient> [-s <sender>] [message]
#   bash .claude/hooks/send-to-teammate.sh -t my-team -r report-writer -s ticker "POLL_TRIGGER"
#   bash .claude/hooks/send-to-teammate.sh -t my-team -r report-writer    # interactive prompt
#
# Options:
#   -t, --team        Team name (required)
#   -r, --recipient   Recipient teammate name (required)
#   -s, --sender      Sender name (default: $USER-script)

set -euo pipefail

SENDER="${USER:-$(whoami)}-script"
TEAM=""
RECIPIENT=""

usage() {
  echo "Usage: $0 -t <team> -r <recipient> [-s <sender>] [message]" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "  -t, --team        Team name (required)" >&2
  echo "  -r, --recipient   Recipient teammate name (required)" >&2
  echo "  -s, --sender      Sender name (default: ${USER:-\$USER}-script)" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--team)      TEAM="$2"; shift 2 ;;
    -r|--recipient) RECIPIENT="$2"; shift 2 ;;
    -s|--sender)    SENDER="$2"; shift 2 ;;
    -h|--help)      usage ;;
    -*)             echo "Unknown option: $1" >&2; usage ;;
    *)              break ;;  # remaining args are the message
  esac
done

if [[ -z "$TEAM" ]]; then
  echo "Error: --team is required." >&2
  usage
fi
if [[ -z "$RECIPIENT" ]]; then
  echo "Error: --recipient is required." >&2
  usage
fi

INBOX="$HOME/.claude/teams/${TEAM}/inboxes/${RECIPIENT}.json"

# Get message from remaining args or prompt
if [[ $# -ge 1 ]]; then
  MESSAGE="$*"
else
  read -rp "Message to ${RECIPIENT}@${TEAM}: " MESSAGE
fi

if [[ -z "$MESSAGE" ]]; then
  echo "No message provided." >&2
  exit 1
fi

# Ensure inbox directory and file exist
mkdir -p "$(dirname "$INBOX")"
if [[ ! -f "$INBOX" ]]; then
  echo "[]" > "$INBOX"
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

# Append message to inbox JSON array
python3 -c "
import json, sys, fcntl

inbox_path = sys.argv[1]
msg = {
    'from': sys.argv[2],
    'text': sys.argv[3],
    'timestamp': sys.argv[4],
    'read': False
}

# Use flock for safe concurrent writes
with open(inbox_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    inbox = json.load(f)
    inbox.append(msg)
    f.seek(0)
    f.truncate()
    json.dump(inbox, f, indent=2)
    fcntl.flock(f, fcntl.LOCK_UN)

label = f'{sys.argv[2]} -> {sys.argv[5]}@{sys.argv[6]}'
text = sys.argv[3]
print(f'{label}: {text[:60]}...' if len(text) > 60 else f'{label}: {text}')
" "$INBOX" "$SENDER" "$MESSAGE" "$TIMESTAMP" "$RECIPIENT" "$TEAM"
