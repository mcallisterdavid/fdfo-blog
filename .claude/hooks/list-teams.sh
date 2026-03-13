#!/usr/bin/env bash
# list-teams.sh — List all agent teams with HQ awareness and worktree discovery.
#
# Extends list-federation.sh with:
#   - Director status at top (reads ~/.claude/hq/config.json)
#   - Worktree discovery via `git worktree list`
#   - Merge-ready flag from HQ worktree status files
#   - Unmanaged worktrees (no active team)
#
# Usage:
#   bash .claude/hooks/list-teams.sh [--all] [--json]
#
# Options:
#   --all   Show all teams including stale ones (default: active only, i.e. modified within 24h)
#   --json  Output machine-readable JSON instead of formatted table

set -euo pipefail

ACTIVE_ONLY=true
JSON_OUTPUT=false
STALE_THRESHOLD=86400  # 24 hours in seconds

usage() {
  echo "Usage: $0 [--all] [--json]" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "  --all   Show all teams including stale ones (default: active only)" >&2
  echo "  --json  Output machine-readable JSON" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)     ACTIVE_ONLY=false; shift ;;
    --json)    JSON_OUTPUT=true; shift ;;
    -h|--help) usage ;;
    -*)        echo "Unknown option: $1" >&2; usage ;;
    *)         echo "Unexpected argument: $1" >&2; usage ;;
  esac
done

TEAMS_DIR="$HOME/.claude/teams"
HQ_DIR="$HOME/.claude/hq"

# Get git worktree list (if in a git repo)
WORKTREE_LIST=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  WORKTREE_LIST=$(git worktree list --porcelain 2>/dev/null || echo "")
fi

python3 -c "
import json, os, sys, time, subprocess

teams_dir = sys.argv[1]
hq_dir = sys.argv[2]
active_only = sys.argv[3] == 'true'
stale_threshold = int(sys.argv[4])
json_output = sys.argv[5] == 'true'
worktree_raw = sys.argv[6]
now = time.time()

# --- Director status ---
hq_config_path = os.path.join(hq_dir, 'config.json')
director = None
if os.path.isfile(hq_config_path):
    try:
        with open(hq_config_path) as f:
            hq_config = json.load(f)
        mtime = os.path.getmtime(hq_config_path)
        age_secs = now - mtime
        is_active = age_secs < stale_threshold
        if age_secs < 3600:
            age_str = f'{int(age_secs / 60)}m ago'
        elif age_secs < 86400:
            age_str = f'{int(age_secs / 3600)}h ago'
        else:
            age_str = f'{int(age_secs / 86400)}d ago'
        director = {
            'team_name': hq_config.get('team_name', 'hq'),
            'worktree': hq_config.get('worktree', ''),
            'branch': hq_config.get('branch', ''),
            'is_active': is_active,
            'age_str': age_str,
        }
    except (json.JSONDecodeError, IOError):
        pass

# --- Parse worktrees from git ---
worktrees = {}
if worktree_raw:
    current_wt = {}
    for line in worktree_raw.split('\n'):
        line = line.strip()
        if not line:
            if 'path' in current_wt:
                worktrees[current_wt['path']] = current_wt
            current_wt = {}
        elif line.startswith('worktree '):
            current_wt['path'] = line[len('worktree '):]
        elif line.startswith('branch '):
            ref = line[len('branch '):]
            current_wt['branch'] = ref.split('/')[-1] if '/' in ref else ref
        elif line == 'bare':
            current_wt['bare'] = True
        elif line == 'detached':
            current_wt['branch'] = '(detached)'
    if 'path' in current_wt:
        worktrees[current_wt['path']] = current_wt

# --- Scan teams ---
teams = []
team_worktrees = set()  # track which worktrees have teams

if os.path.isdir(teams_dir):
    for entry in sorted(os.listdir(teams_dir)):
        config_path = os.path.join(teams_dir, entry, 'config.json')
        if not os.path.isfile(config_path):
            continue
        try:
            with open(config_path) as f:
                config = json.load(f)
        except (json.JSONDecodeError, IOError):
            continue

        mtime = os.path.getmtime(config_path)
        age_secs = now - mtime
        is_active = age_secs < stale_threshold

        if active_only and not is_active:
            continue

        name = config.get('name', entry)
        description = config.get('description', '(no description)')
        members = config.get('members', [])
        member_count = len(members)

        # Extract worktree from first member's cwd
        worktree = ''
        worktree_path = ''
        if members and 'cwd' in members[0]:
            cwd = members[0]['cwd']
            worktree = os.path.basename(cwd)
            worktree_path = cwd
            team_worktrees.add(cwd)

        # Human-readable age
        if age_secs < 3600:
            age_str = f'{int(age_secs / 60)}m ago'
        elif age_secs < 86400:
            age_str = f'{int(age_secs / 3600)}h ago'
        else:
            age_str = f'{int(age_secs / 86400)}d ago'

        # Check HQ worktree status
        merge_ready = False
        hq_status = ''
        hq_summary = ''
        branch = ''
        if worktree_path:
            # Try to find the branch for this worktree
            for wt_path, wt_info in worktrees.items():
                if wt_path == worktree_path:
                    branch = wt_info.get('branch', '')
                    break

        if branch:
            hq_status_path = os.path.join(hq_dir, 'worktrees', f'{branch}.json')
            if os.path.isfile(hq_status_path):
                try:
                    with open(hq_status_path) as f:
                        hq_data = json.load(f)
                    merge_ready = hq_data.get('merge_ready', False)
                    hq_status = hq_data.get('status', '')
                    hq_summary = hq_data.get('summary', '')
                except (json.JSONDecodeError, IOError):
                    pass

        teams.append({
            'name': name,
            'description': description,
            'worktree': worktree,
            'branch': branch,
            'member_count': member_count,
            'is_active': is_active,
            'age_str': age_str,
            'mtime': mtime,
            'merge_ready': merge_ready,
            'hq_status': hq_status,
            'hq_summary': hq_summary,
        })

# Sort by mtime descending (most recent first)
teams.sort(key=lambda t: t['mtime'], reverse=True)

# --- Unmanaged worktrees ---
unmanaged = []
for wt_path, wt_info in worktrees.items():
    if wt_path not in team_worktrees and not wt_info.get('bare'):
        unmanaged.append({
            'path': wt_path,
            'branch': wt_info.get('branch', '(unknown)'),
            'name': os.path.basename(wt_path),
        })

# --- Output ---
if json_output:
    output = {
        'director': director,
        'teams': teams,
        'unmanaged_worktrees': unmanaged,
    }
    print(json.dumps(output, indent=2))
else:
    # Director status
    if director:
        status = 'active' if director['is_active'] else 'stale'
        print(f\"DIRECTOR: {status} (branch: {director['branch']}, {director['age_str']})\")
    else:
        print('DIRECTOR: not running')
    print()

    # Teams
    active_count = sum(1 for t in teams if t['is_active'])
    stale_count = len(teams) - active_count

    if not teams:
        print('No teams found.')
    else:
        if active_only:
            print(f'TEAMS ({active_count} active):')
        else:
            print(f'TEAMS ({active_count} active, {stale_count} stale):')

        for t in teams:
            status = '[active]' if t['is_active'] else '[stale] '
            merge = 'MERGE-READY' if t['merge_ready'] else ''
            summary = t['hq_summary'][:40] + '...' if len(t['hq_summary']) > 40 else t['hq_summary']
            if not summary:
                summary = t['description'][:40] + '...' if len(t['description']) > 40 else t['description']
            branch_str = f\"branch: {t['branch']}\" if t['branch'] else f\"wt: {t['worktree']}\"
            merge_str = f'  {merge}' if merge else ''
            print(f\"  {t['name']:<25s} {status}  {t['age_str']:<8s} {branch_str:<25s}{merge_str:<15s} \\\"{summary}\\\"  members: {t['member_count']}\")

    # Unmanaged worktrees
    if unmanaged:
        print()
        print(f'UNMANAGED WORKTREES ({len(unmanaged)}):')
        for wt in unmanaged:
            print(f\"  {wt['name']:<25s} branch: {wt['branch']:<20s} {wt['path']}\")
" "$TEAMS_DIR" "$HQ_DIR" "$ACTIVE_ONLY" "$STALE_THRESHOLD" "$JSON_OUTPUT" "$WORKTREE_LIST"
