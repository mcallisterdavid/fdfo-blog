#!/usr/bin/env bash
# report-to-hq.sh — Team lead reports status upward to the HQ director.
#
# Writes structured status to ~/.claude/hq/worktrees/<branch>.json,
# writes to the director's TeammateMailbox inbox (auto-polled by
# Claude Code), and appends to ~/.claude/hq/inbox.json (legacy, for
# /hq inbox consumption). Also checks for unread director messages.
#
# The director's inbox is resolved dynamically:
# 1. If ~/.claude/hq/config.json has actual_team_name, use that team's inbox
# 2. Fall back to ~/.claude/teams/hq/inboxes/team-lead.json (canonical path)
# 3. If init-director.sh created a symlink from hq -> actual team, both resolve
#    to the same file. If no symlink exists, writes to both paths for redundancy.
#
# Usage:
#   bash .claude/hooks/report-to-hq.sh \
#     --from-team <team> --branch <branch> --worktree <path> \
#     [--status running|completed|failed|paused] \
#     [--merge-ready] [--merge-target <branch>] \
#     [--merge-type merge|cherry-pick] [--merge-commits <h1,h2,...>] \
#     [--findings "finding1" --findings "finding2"] \
#     <summary-message>
#
# Examples:
#   bash .claude/hooks/report-to-hq.sh \
#     --from-team fish-humanoid --branch fish-fast-humanoid \
#     --worktree /home/user/FAR-cmk-test.fish-fast-humanoid \
#     "FastTD3 at 150k iters, reward 1850. No alerts."
#
#   bash .claude/hooks/report-to-hq.sh \
#     --from-team fish-humanoid --branch fish-fast-humanoid \
#     --worktree /home/user/FAR-cmk-test.fish-fast-humanoid \
#     --merge-ready --merge-target fish \
#     "Branch ready for merge. All tests pass."

set -euo pipefail

FROM_TEAM=""
BRANCH=""
WORKTREE=""
STATUS="running"
MERGE_READY=false
MERGE_TARGET="main"
MERGE_TYPE="merge"
MERGE_COMMITS=""
FINDINGS=()

HQ_DIR="$HOME/.claude/hq"
LOG_FILE="${HQ_DIR}/message-log.jsonl"

usage() {
  echo "Usage: $0 --from-team <team> --branch <branch> --worktree <path> [options] <summary-message>" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "  --status running|completed|failed|paused  Team status (default: running)" >&2
  echo "  --merge-ready                             Declare branch merge-ready" >&2
  echo "  --merge-target <branch>                   Branch to merge into (default: main)" >&2
  echo "  --merge-type merge|cherry-pick            Integration type (default: merge)" >&2
  echo "  --merge-commits <h1,h2,...>               Commits for cherry-pick" >&2
  echo "  --findings <text>                         Key finding (repeatable)" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-team)      FROM_TEAM="$2"; shift 2 ;;
    --branch)         BRANCH="$2"; shift 2 ;;
    --worktree)       WORKTREE="$2"; shift 2 ;;
    --status)         STATUS="$2"; shift 2 ;;
    --merge-ready)    MERGE_READY=true; shift ;;
    --merge-target)   MERGE_TARGET="$2"; shift 2 ;;
    --merge-type)     MERGE_TYPE="$2"; shift 2 ;;
    --merge-commits)  MERGE_COMMITS="$2"; shift 2 ;;
    --findings)       FINDINGS+=("$2"); shift 2 ;;
    -h|--help)        usage ;;
    -*)               echo "Unknown option: $1" >&2; usage ;;
    *)                break ;;  # remaining args are the summary message
  esac
done

if [[ -z "$FROM_TEAM" ]]; then
  echo "Error: --from-team is required." >&2
  usage
fi
if [[ -z "$BRANCH" ]]; then
  echo "Error: --branch is required." >&2
  usage
fi
if [[ -z "$WORKTREE" ]]; then
  echo "Error: --worktree is required." >&2
  usage
fi

# Get summary from remaining args
if [[ $# -ge 1 ]]; then
  SUMMARY="$*"
else
  read -rp "Status report from ${FROM_TEAM}: " SUMMARY
fi

if [[ -z "$SUMMARY" ]]; then
  echo "No summary message provided." >&2
  exit 1
fi

# --- Layer 1: Check for unread director messages (soft enforcement) ---
INBOX_FILE="$HOME/.claude/teams/${FROM_TEAM}/inboxes/team-lead.json"
if [[ -f "$INBOX_FILE" ]]; then
  UNREAD_COUNT=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        messages = json.load(f)
    unread = [m for m in messages if 'director@hq' in m.get('from', '') and not m.get('read', False)]
    print(len(unread))
except (FileNotFoundError, json.JSONDecodeError):
    print(0)
" "$INBOX_FILE" 2>/dev/null || echo "0")

  if [[ "$UNREAD_COUNT" -gt 0 ]]; then
    echo "WARNING: ${UNREAD_COUNT} unread director message(s). Run /hq inbox to review." >&2
  fi
fi

# --- Write worktree status file ---
mkdir -p "${HQ_DIR}/worktrees"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
HEAD_COMMIT=$(git -C "$WORKTREE" rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Convert findings array to JSON
FINDINGS_JSON="[]"
if [[ ${#FINDINGS[@]} -gt 0 ]]; then
  FINDINGS_JSON=$(printf '%s\n' "${FINDINGS[@]}" | python3 -c "import json, sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
fi

# Convert merge_commits to JSON array
COMMITS_JSON="[]"
if [[ -n "$MERGE_COMMITS" ]]; then
  COMMITS_JSON=$(echo "$MERGE_COMMITS" | python3 -c "import json, sys; print(json.dumps(sys.stdin.read().strip().split(',')))")
fi

python3 -c "
import json, sys, fcntl

status_file = sys.argv[1]
data = {
    'branch': sys.argv[2],
    'worktree_path': sys.argv[3],
    'team_name': sys.argv[4],
    'status': sys.argv[5],
    'merge_ready': sys.argv[6] == 'true',
    'merge_target': sys.argv[7],
    'merge_type': sys.argv[8],
    'merge_commits': json.loads(sys.argv[9]),
    'summary': sys.argv[10],
    'key_findings': json.loads(sys.argv[11]),
    'head_commit': sys.argv[12],
    'reported_at': sys.argv[13],
}

with open(status_file, 'w') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    json.dump(data, f, indent=2)
    f.write('\n')
    fcntl.flock(f, fcntl.LOCK_UN)
" "${HQ_DIR}/worktrees/${BRANCH}.json" \
  "$BRANCH" "$WORKTREE" "$FROM_TEAM" "$STATUS" \
  "$MERGE_READY" "$MERGE_TARGET" "$MERGE_TYPE" "$COMMITS_JSON" \
  "$SUMMARY" "$FINDINGS_JSON" "$HEAD_COMMIT" "$TIMESTAMP"

# --- Construct HQ-REPORT message ---
MERGE_STATUS="no"
if [[ "$MERGE_READY" == true ]]; then
  MERGE_STATUS="yes (target: ${MERGE_TARGET}, type: ${MERGE_TYPE})"
fi

FINDINGS_TEXT=""
if [[ ${#FINDINGS[@]} -gt 0 ]]; then
  FINDINGS_TEXT=$(printf '; %s' "${FINDINGS[@]}")
  FINDINGS_TEXT="${FINDINGS_TEXT:2}"  # strip leading '; '
fi

REPORT_BODY="HQ-REPORT: [${STATUS}] ${SUMMARY}
Branch: ${BRANCH}, Team: ${FROM_TEAM}
Merge-ready: ${MERGE_STATUS}"

if [[ -n "$FINDINGS_TEXT" ]]; then
  REPORT_BODY="${REPORT_BODY}
Findings: ${FINDINGS_TEXT}"
fi

# --- Write to director's TeammateMailbox (auto-polled by Claude Code) ---
# The director's actual team name may differ from "hq" if TeamCreate assigned a
# random name (e.g., "fizzy-plotting-alpaca"). init-director.sh creates a symlink
# from ~/.claude/teams/hq -> ~/.claude/teams/<actual-name>, so writing to the "hq"
# path delivers to the correct inbox. We also check ~/.claude/hq/config.json for the
# actual team name as a fallback (writes directly to the actual team's inbox).
DIRECTOR_TEAM="hq"
HQ_CONFIG_FILE="${HQ_DIR}/config.json"
if [[ -f "$HQ_CONFIG_FILE" ]]; then
  ACTUAL_TEAM=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        config = json.load(f)
    # actual_team_name is set by init-director.sh; fall back to team_name
    print(config.get('actual_team_name', config.get('team_name', 'hq')))
except Exception:
    print('hq')
" "$HQ_CONFIG_FILE" 2>/dev/null || echo "hq")
  if [[ -n "$ACTUAL_TEAM" && "$ACTUAL_TEAM" != "hq" ]]; then
    DIRECTOR_TEAM="$ACTUAL_TEAM"
  fi
fi

# Write to the canonical "hq" path (which may be a symlink to the actual team).
# Also write to the actual team path directly if different, for redundancy.
DIRECTOR_INBOX="$HOME/.claude/teams/hq/inboxes/team-lead.json"
mkdir -p "$(dirname "$DIRECTOR_INBOX")"

# If the actual team name differs, also ensure its inbox dir exists
ACTUAL_INBOX=""
if [[ "$DIRECTOR_TEAM" != "hq" ]]; then
  ACTUAL_INBOX="$HOME/.claude/teams/${DIRECTOR_TEAM}/inboxes/team-lead.json"
  mkdir -p "$(dirname "$ACTUAL_INBOX")"
fi

python3 -c "
import json, sys, fcntl, os

def write_to_inbox(inbox_path, msg):
    \"\"\"Append a message to a JSON array inbox file with file locking.\"\"\"
    # Create file with empty array if missing
    if not os.path.isfile(inbox_path):
        with open(inbox_path, 'w') as f:
            json.dump([], f)

    with open(inbox_path, 'r+') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            inbox = json.load(f)
        except json.JSONDecodeError:
            inbox = []
        inbox.append(msg)
        f.seek(0)
        f.truncate()
        json.dump(inbox, f, indent=2)
        f.write('\n')
        fcntl.flock(f, fcntl.LOCK_UN)

canonical_path = sys.argv[1]
actual_path = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else ''
msg = {
    'from': sys.argv[2],
    'text': sys.argv[3],
    'timestamp': sys.argv[4],
    'read': False
}

# Write to the canonical 'hq' inbox (may be a symlink)
write_to_inbox(canonical_path, msg)

# If the actual team path differs AND is not the same file (i.e., no symlink),
# write there too for redundancy. This handles the case where the symlink was
# not created (e.g., init-director.sh was not run).
if actual_path and os.path.realpath(actual_path) != os.path.realpath(canonical_path):
    write_to_inbox(actual_path, msg)
    print(f'Also wrote to actual team inbox: {actual_path}', file=sys.stderr)
" "$DIRECTOR_INBOX" "team-lead@${FROM_TEAM}" "$REPORT_BODY" "$TIMESTAMP" "$ACTUAL_INBOX"

# --- Log to HQ message log ---
mkdir -p "$HQ_DIR"
PREVIEW="${SUMMARY:0:80}"

python3 -c "
import json, sys, fcntl

log_file = sys.argv[1]
entry = {
    'timestamp': sys.argv[2],
    'from_team': sys.argv[3],
    'branch': sys.argv[4],
    'status': sys.argv[5],
    'merge_ready': sys.argv[6] == 'true',
    'message_preview': sys.argv[7],
}

with open(log_file, 'a') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.write(json.dumps(entry) + '\n')
    fcntl.flock(f, fcntl.LOCK_UN)
" "$LOG_FILE" "$TIMESTAMP" "$FROM_TEAM" "$BRANCH" "$STATUS" "$MERGE_READY" "$PREVIEW"

# --- Append to HQ inbox.json for /hq inbox consumption ---
HQ_INBOX="${HQ_DIR}/inbox.json"

python3 -c "
import json, sys, fcntl, os

inbox_path = sys.argv[1]
msg = {
    'from': sys.argv[2],
    'text': sys.argv[3],
    'timestamp': sys.argv[4],
    'read': False
}

# Create file with empty array if missing
if not os.path.isfile(inbox_path):
    with open(inbox_path, 'w') as f:
        json.dump([], f)

with open(inbox_path, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        inbox = json.load(f)
    except json.JSONDecodeError:
        inbox = []
    inbox.append(msg)
    f.seek(0)
    f.truncate()
    json.dump(inbox, f, indent=2)
    f.write('\n')
    fcntl.flock(f, fcntl.LOCK_UN)
" "$HQ_INBOX" "team-lead@${FROM_TEAM}" "$REPORT_BODY" "$TIMESTAMP"

if [[ "$DIRECTOR_TEAM" != "hq" ]]; then
  echo "Report sent to director (team: ${DIRECTOR_TEAM}, via canonical path: hq)."
else
  echo "Report sent to director (team: hq)."
fi
