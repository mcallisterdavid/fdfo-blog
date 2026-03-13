#!/usr/bin/env bash
# init-director.sh — Initialize the HQ director session for reliable TeammateMailbox delivery.
#
# This script solves the "random team name" problem: when the director calls
# TeamCreate(team_name="hq"), Claude Code may assign a random name (e.g.,
# "fizzy-plotting-alpaca") if ~/.claude/teams/hq/ already exists. Team leads
# report to ~/.claude/teams/hq/inboxes/, but the director's session polls the
# actual (possibly random) team's inbox. This script bridges the gap.
#
# Two-phase usage:
#
#   Phase 1 (BEFORE TeamCreate):
#     bash .claude/hooks/init-director.sh --pre
#     # Then run: TeamCreate(team_name="hq")
#
#   Phase 2 (AFTER TeamCreate):
#     bash .claude/hooks/init-director.sh --post <actual-team-name>
#     # <actual-team-name> is whatever TeamCreate returned (e.g., "hq" or "fizzy-plotting-alpaca")
#
# What each phase does:
#
#   --pre:
#     - Removes stale ~/.claude/teams/hq/ (so TeamCreate can use the name "hq")
#     - Removes stale ~/.claude/hq/ state
#     - Creates fresh ~/.claude/hq/ directory
#
#   --post <name>:
#     - If <name> is "hq": no symlink needed, just ensures inbox dir exists
#     - If <name> is NOT "hq": creates ~/.claude/teams/hq as a symlink to
#       ~/.claude/teams/<name>, so report-to-hq.sh writes land in the right place
#     - Writes ~/.claude/hq/config.json with the actual team name
#     - Verifies the inbox path is reachable
#
# Single-command usage (does both phases, for scripts):
#     bash .claude/hooks/init-director.sh --post <actual-team-name>
#   (Safe to run without --pre if stale state was already cleaned.)

set -euo pipefail

HQ_DIR="$HOME/.claude/hq"
TEAMS_DIR="$HOME/.claude/teams"
CANONICAL_TEAM="hq"

usage() {
  echo "Usage:" >&2
  echo "  $0 --pre                    # Phase 1: clean stale state before TeamCreate" >&2
  echo "  $0 --post <actual-team-name> # Phase 2: bridge inbox after TeamCreate" >&2
  exit 1
}

phase_pre() {
  echo "=== init-director: Phase 1 (pre-TeamCreate) ==="

  # Remove stale HQ team directory so TeamCreate can claim the name "hq"
  if [[ -d "${TEAMS_DIR}/${CANONICAL_TEAM}" ]] || [[ -L "${TEAMS_DIR}/${CANONICAL_TEAM}" ]]; then
    echo "Removing stale ${TEAMS_DIR}/${CANONICAL_TEAM}"
    rm -rf "${TEAMS_DIR}/${CANONICAL_TEAM}"
  fi

  # Remove stale HQ state
  if [[ -d "$HQ_DIR" ]]; then
    echo "Removing stale ${HQ_DIR}"
    rm -rf "$HQ_DIR"
  fi

  # Create fresh HQ directory structure
  mkdir -p "${HQ_DIR}/worktrees"
  echo "Created fresh ${HQ_DIR}"

  echo ""
  echo "Ready for TeamCreate. Run:"
  echo "  TeamCreate(team_name=\"hq\")"
  echo ""
  echo "Then run Phase 2 with the actual team name TeamCreate returned:"
  echo "  bash .claude/hooks/init-director.sh --post <actual-team-name>"
}

phase_post() {
  local actual_name="$1"

  echo "=== init-director: Phase 2 (post-TeamCreate) ==="
  echo "Actual team name from TeamCreate: ${actual_name}"

  # Ensure HQ directory exists (in case --pre was skipped)
  mkdir -p "${HQ_DIR}/worktrees"

  if [[ "$actual_name" == "$CANONICAL_TEAM" ]]; then
    # TeamCreate used "hq" as the name — no symlink needed
    echo "TeamCreate used the canonical name 'hq'. No symlink needed."
    mkdir -p "${TEAMS_DIR}/${CANONICAL_TEAM}/inboxes"
  else
    # TeamCreate assigned a different name — we need a symlink
    echo "TeamCreate assigned a different name: ${actual_name}"

    # Verify the actual team directory exists
    if [[ ! -d "${TEAMS_DIR}/${actual_name}" ]]; then
      echo "ERROR: ${TEAMS_DIR}/${actual_name} does not exist." >&2
      echo "Did TeamCreate really return '${actual_name}'?" >&2
      exit 1
    fi

    # Ensure the actual team's inbox directory exists
    mkdir -p "${TEAMS_DIR}/${actual_name}/inboxes"

    # Remove any existing hq entry (file, dir, or symlink)
    if [[ -e "${TEAMS_DIR}/${CANONICAL_TEAM}" ]] || [[ -L "${TEAMS_DIR}/${CANONICAL_TEAM}" ]]; then
      echo "Removing existing ${TEAMS_DIR}/${CANONICAL_TEAM}"
      rm -rf "${TEAMS_DIR}/${CANONICAL_TEAM}"
    fi

    # Create symlink: ~/.claude/teams/hq -> ~/.claude/teams/<actual-name>
    ln -s "${TEAMS_DIR}/${actual_name}" "${TEAMS_DIR}/${CANONICAL_TEAM}"
    echo "Created symlink: ${TEAMS_DIR}/${CANONICAL_TEAM} -> ${TEAMS_DIR}/${actual_name}"
  fi

  # Write HQ config with the actual team name
  local director_branch
  director_branch=$(git branch --show-current 2>/dev/null || echo "unknown")
  local director_worktree
  director_worktree=$(pwd)
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

  python3 -c "
import json, sys

config = {
    'team_name': sys.argv[1],
    'actual_team_name': sys.argv[1],
    'canonical_team_name': 'hq',
    'branch': sys.argv[2],
    'worktree': sys.argv[3],
    'started_at': sys.argv[4],
    'created_by': 'init-director.sh',
    'symlinked': sys.argv[1] != 'hq',
}

with open(sys.argv[5], 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
" "$actual_name" "$director_branch" "$director_worktree" "$timestamp" "${HQ_DIR}/config.json"

  echo "Wrote ${HQ_DIR}/config.json (actual_team_name: ${actual_name})"

  # Verify inbox is reachable via the canonical path
  local inbox_path="${TEAMS_DIR}/${CANONICAL_TEAM}/inboxes/team-lead.json"
  local inbox_dir
  inbox_dir=$(dirname "$inbox_path")
  if [[ -d "$inbox_dir" ]]; then
    echo "Inbox directory OK: ${inbox_dir}"
  else
    echo "ERROR: Inbox directory not reachable at ${inbox_dir}" >&2
    exit 1
  fi

  # Create empty inbox file if it doesn't exist (so report-to-hq.sh doesn't need to)
  if [[ ! -f "$inbox_path" ]]; then
    echo "[]" > "$inbox_path"
    echo "Created empty inbox: ${inbox_path}"
  fi

  echo ""
  echo "Director session initialized successfully."
  echo "Team leads reporting via report-to-hq.sh will deliver to:"
  echo "  ${inbox_path}"
  if [[ "$actual_name" != "$CANONICAL_TEAM" ]]; then
    echo "Which symlinks to:"
    echo "  ${TEAMS_DIR}/${actual_name}/inboxes/team-lead.json"
    echo "(This is the path Claude Code's TeammateMailbox polls.)"
  fi
}

# --- Parse arguments ---
if [[ $# -lt 1 ]]; then
  usage
fi

case "$1" in
  --pre)
    phase_pre
    ;;
  --post)
    if [[ $# -lt 2 ]]; then
      echo "Error: --post requires the actual team name." >&2
      usage
    fi
    phase_post "$2"
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage
    ;;
esac
