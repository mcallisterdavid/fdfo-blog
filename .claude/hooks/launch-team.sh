#!/usr/bin/env bash
# launch-team.sh — Spawn a team lead in a new tmux window targeting a specific worktree.
#
# The HQ director uses this to launch team leads. Each lead gets:
#   - A dedicated tmux window with a short name
#   - An appended system prompt with HQ communication instructions
#   - A mission prompt as the first user message
#
# Usage:
#   bash .claude/hooks/launch-team.sh \
#     --worktree <path> --name <short-name> \
#     --mission <text-or-file> \
#     [--model opus|sonnet] [--permission-mode default|dontAsk]
#
# By default, launched sessions use --dangerously-skip-permissions to avoid
# sandbox restrictions (bwrap failures) and permission prompts that block
# unattended team leads. Pass --sandbox to disable this and run sandboxed.
#
# Examples:
#   bash .claude/hooks/launch-team.sh \
#     --worktree /home/user/FAR-cmk-test.fish-fast-humanoid \
#     --name humanoid \
#     --mission "Run FastTD3 on humanoid walk task, target reward 2000"
#
#   bash .claude/hooks/launch-team.sh \
#     --worktree /home/user/FAR-cmk-test.fish-hlgauss \
#     --name hlgauss \
#     --mission /tmp/claude/hlgauss-mission.md \
#     --model sonnet --sandbox

set -euo pipefail

WORKTREE=""
NAME=""
MISSION=""
MODEL=""
PERMISSION_MODE=""
SANDBOX=false  # default: no sandbox (use --dangerously-skip-permissions)

HQ_DIR="$HOME/.claude/hq"
TMP_DIR="/tmp/claude"

usage() {
  echo "Usage: $0 --worktree <path> --name <short-name> --mission <text-or-file> [options]" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "  --model opus|sonnet               Claude model (default: inherits from environment)" >&2
  echo "  --permission-mode default|dontAsk  Permission mode for the session" >&2
  echo "  --sandbox                         Run sandboxed (default: no sandbox, uses --dangerously-skip-permissions)" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree)         WORKTREE="$2"; shift 2 ;;
    --name)             NAME="$2"; shift 2 ;;
    --mission)          MISSION="$2"; shift 2 ;;
    --model)            MODEL="$2"; shift 2 ;;
    --permission-mode)  PERMISSION_MODE="$2"; shift 2 ;;
    --sandbox)          SANDBOX=true; shift ;;
    -h|--help)          usage ;;
    -*)                 echo "Unknown option: $1" >&2; usage ;;
    *)                  echo "Unexpected argument: $1" >&2; usage ;;
  esac
done

if [[ -z "$WORKTREE" ]]; then
  echo "Error: --worktree is required." >&2
  usage
fi
if [[ -z "$NAME" ]]; then
  echo "Error: --name is required." >&2
  usage
fi
if [[ -z "$MISSION" ]]; then
  echo "Error: --mission is required." >&2
  usage
fi

# Validate worktree
if [[ ! -d "$WORKTREE" ]]; then
  echo "Error: worktree directory does not exist: $WORKTREE" >&2
  exit 1
fi
if ! git -C "$WORKTREE" rev-parse --git-dir >/dev/null 2>&1; then
  echo "Error: not a git worktree: $WORKTREE" >&2
  exit 1
fi

# Determine branch
BRANCH=$(git -C "$WORKTREE" branch --show-current 2>/dev/null || echo "detached")

# Check if tmux is available
if ! command -v tmux >/dev/null 2>&1; then
  echo "Error: tmux is not available." >&2
  exit 1
fi

# Check if we're in a tmux session
if [[ -z "${TMUX:-}" ]]; then
  echo "Error: not running inside a tmux session." >&2
  exit 1
fi

# Check if a window with this name already exists
if tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qx "$NAME"; then
  echo "WARNING: tmux window '$NAME' already exists. Launching anyway." >&2
fi

# Resolve mission text
MISSION_TEXT=""
if [[ -f "$MISSION" ]]; then
  MISSION_TEXT=$(cat "$MISSION")
else
  MISSION_TEXT="$MISSION"
fi

# Create tmp directory
mkdir -p "$TMP_DIR"

# --- Ensure HQ infrastructure exists ---
# report-to-hq.sh reads ~/.claude/hq/config.json to find the director's inbox.
# When the director cleans up stale state (rm -rf ~/.claude/hq) then creates the
# hq team via TeamCreate, config.json is NOT recreated — TeamCreate only writes
# to ~/.claude/teams/hq/. Without config.json, report-to-hq.sh can't find the
# director and inbox delivery silently fails (worktree status file still gets
# written, but no message reaches the director). This block ensures the config
# exists so that team leads can always report back.
HQ_CONFIG="${HQ_DIR}/config.json"
if [[ ! -f "$HQ_CONFIG" ]]; then
  mkdir -p "$HQ_DIR"
  DIRECTOR_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
  DIRECTOR_WORKTREE=$(pwd)
  DIRECTOR_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
  python3 -c "
import json, sys
config = {
    'team_name': 'hq',
    'branch': sys.argv[1],
    'worktree': sys.argv[2],
    'started_at': sys.argv[3],
    'auto_created_by': 'launch-team.sh',
}
with open(sys.argv[4], 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
" "$DIRECTOR_BRANCH" "$DIRECTOR_WORKTREE" "$DIRECTOR_TIMESTAMP" "$HQ_CONFIG"
  echo "Created HQ config at ${HQ_CONFIG} (was missing after stale state cleanup)." >&2
fi

# Ensure the director's inbox directory exists so send-to-teammate.sh can deliver
mkdir -p "$HOME/.claude/teams/hq/inboxes"

# Write system prompt supplement
cat > "${TMP_DIR}/hq-${NAME}-system.md" << SYSEOF
You are a team lead managed by the HQ director. After reading your mission below:

1. Create your team via TeamCreate(team_name="${NAME}")
2. Spawn teammates as needed for your mission (runners, code-writers, report-writer, etc.)
3. Start the background ticker immediately after spawning report-writer
4. Follow standard team lead practices from docs/making-agent-teams.md

## HQ Communication

- Report status to director: /hq report "your status update"
- Report merge readiness: /hq report --merge-ready "branch is ready"
- Report key findings: /hq report --finding "important result" "status"
- Check for director messages: /hq inbox
- Director messages arrive in your normal team inbox with from="director@hq"

MANDATORY: Check /hq inbox at every phase transition, after every
report-writer cycle summary, and before reporting merge-ready.
If you receive a DIRECTIVE [HIGH] [ACTION], prioritize it over current work.

## Team Persistence (CRITICAL)

NEVER call TeamDelete or delete your team config, even when your task is
"done." Your team is the communication channel — without it, the director
cannot send you follow-up directives and messages go undelivered. When your
task finishes: shut down teammates, /hq report your final status, then
stay idle and wait. Only the director disbands teams.

## Context

- Worktree: ${WORKTREE}
- Branch: ${BRANCH}
- Team name: ${NAME}
- Tmux pane ID: written to ${HQ_DIR}/worktrees/${BRANCH}.json after launch
SYSEOF

# Write mission prompt
cat > "${TMP_DIR}/hq-${NAME}-mission.md" << MISSEOF
${MISSION_TEXT}
MISSEOF

# Build claude command arguments
CLAUDE_ARGS="--append-system-prompt \"\$(cat '${TMP_DIR}/hq-${NAME}-system.md')\""
if [[ -n "$MODEL" ]]; then
  CLAUDE_ARGS="${CLAUDE_ARGS} --model ${MODEL}"
fi
if [[ -n "$PERMISSION_MODE" ]]; then
  CLAUDE_ARGS="${CLAUDE_ARGS} --permission-mode ${PERMISSION_MODE}"
fi

# Write launcher script (avoids quoting issues in tmux command)
cat > "${TMP_DIR}/hq-${NAME}-launch.sh" << 'LAUNCHEOF'
#!/usr/bin/env bash
set -euo pipefail
LAUNCHEOF

cat >> "${TMP_DIR}/hq-${NAME}-launch.sh" << LAUNCHEOF
cd "${WORKTREE}"
unset CLAUDECODE  # Allow launching Claude inside existing session context
# TMUX_PANE is already set correctly by tmux for new panes.
# Do NOT override it — tmux display-message -p in a detached window
# returns the ACTIVE pane's ID, not this pane's ID, causing sub-agents
# to spawn in the wrong window.
exec claude \\
  --append-system-prompt "\$(cat '${TMP_DIR}/hq-${NAME}-system.md')" \\
LAUNCHEOF

# Default: skip permissions and sandbox to avoid bwrap failures and blocking prompts
if [[ "$SANDBOX" == "false" ]]; then
  echo "  --dangerously-skip-permissions \\" >> "${TMP_DIR}/hq-${NAME}-launch.sh"
fi
if [[ -n "$MODEL" ]]; then
  echo "  --model ${MODEL} \\" >> "${TMP_DIR}/hq-${NAME}-launch.sh"
fi
if [[ -n "$PERMISSION_MODE" ]]; then
  echo "  --permission-mode ${PERMISSION_MODE} \\" >> "${TMP_DIR}/hq-${NAME}-launch.sh"
fi

echo "  \"\$(cat '${TMP_DIR}/hq-${NAME}-mission.md')\"" >> "${TMP_DIR}/hq-${NAME}-launch.sh"

chmod +x "${TMP_DIR}/hq-${NAME}-launch.sh"

# Launch in a new tmux window (detached — focus stays on director)
# Use -P -F to capture the pane ID for safe cleanup later (TMUX SAFETY)
TMUX_PANE_ID=$(tmux new-window -n "$NAME" -d -P -F '#{pane_id}' "bash '${TMP_DIR}/hq-${NAME}-launch.sh'")

# Register launch in HQ worktree status
mkdir -p "${HQ_DIR}/worktrees"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
HEAD_COMMIT=$(git -C "$WORKTREE" rev-parse --short HEAD 2>/dev/null || echo "unknown")

python3 -c "
import json, sys, os, fcntl

status_file = sys.argv[1]
data = {
    'branch': sys.argv[2],
    'worktree_path': sys.argv[3],
    'team_name': sys.argv[4],
    'status': 'launched',
    'merge_ready': False,
    'merge_target': 'main',
    'merge_type': 'merge',
    'merge_commits': [],
    'summary': 'Team lead launched, setting up...',
    'key_findings': [],
    'head_commit': sys.argv[5],
    'reported_at': sys.argv[6],
    'tmux_pane_id': sys.argv[7],
}

with open(status_file, 'w') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    json.dump(data, f, indent=2)
    f.write('\n')
    fcntl.flock(f, fcntl.LOCK_UN)
" "${HQ_DIR}/worktrees/${BRANCH}.json" "$BRANCH" "$WORKTREE" "$NAME" "$HEAD_COMMIT" "$TIMESTAMP" "$TMUX_PANE_ID"

# Patch tmuxPaneId into team config once the team lead creates it via TeamCreate.
# TeamCreate writes ~/.claude/teams/<name>/config.json with members[], but the
# team-lead member gets tmuxPaneId="" because the lead doesn't know its own pane.
# We poll in the background until the config appears and has a members array with
# a team-lead entry, then inject the pane ID.
(
  TEAM_CONFIG="$HOME/.claude/teams/${NAME}/config.json"
  MAX_WAIT=120  # seconds to wait for TeamCreate
  POLL_INTERVAL=2
  elapsed=0

  # Wait for config file to exist AND contain a team-lead member
  while (( elapsed < MAX_WAIT )); do
    if [[ -f "$TEAM_CONFIG" ]] && python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        config = json.load(f)
    members = config.get('members', [])
    # Check for team-lead by role, name, or just take the first member
    has_lead = any(
        m.get('role') == 'team-lead' or m.get('name') == 'team-lead'
        for m in members
    ) or len(members) > 0
    sys.exit(0 if has_lead else 1)
except Exception:
    sys.exit(1)
" "$TEAM_CONFIG" 2>/dev/null; then
      break
    fi
    sleep "$POLL_INTERVAL"
    (( elapsed += POLL_INTERVAL ))
  done

  if [[ -f "$TEAM_CONFIG" ]]; then
    python3 -c "
import json, sys, fcntl

config_path = sys.argv[1]
pane_id = sys.argv[2]

# Read with lock
with open(config_path, 'r') as f:
    fcntl.flock(f, fcntl.LOCK_SH)
    config = json.load(f)
    fcntl.flock(f, fcntl.LOCK_UN)

# Find the team-lead member and set tmuxPaneId.
# Match by role or name; fall back to first member if neither matches.
patched = False
target = None
for member in config.get('members', []):
    if member.get('role') == 'team-lead' or member.get('name') == 'team-lead':
        target = member
        break

# Fallback: first member is typically the team lead (creator)
if target is None and config.get('members'):
    target = config['members'][0]

if target is not None and not target.get('tmuxPaneId'):
    target['tmuxPaneId'] = pane_id
    patched = True

if patched:
    with open(config_path, 'w') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        json.dump(config, f, indent=2)
        f.write('\n')
        fcntl.flock(f, fcntl.LOCK_UN)
" "$TEAM_CONFIG" "$TMUX_PANE_ID"
  fi
) &
disown  # detach from shell so launch-team.sh can exit immediately

echo "Launched team lead '${NAME}' in worktree ${WORKTREE} (branch: ${BRANCH})"
