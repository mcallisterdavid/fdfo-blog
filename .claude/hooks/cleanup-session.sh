#!/usr/bin/env bash
# cleanup-session.sh — Remove worktrees, branches, team dirs, and project dirs after archiving.
#
# Usage:
#   cleanup-session.sh --archive <archive-path> [--keep-branches]
#   cleanup-session.sh --worktrees <path1,...> --teams <t1,...> [--keep-branches]
#
# Safety: When using --archive, reads manifest.json to know exactly what to clean.

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
HQ_DIR="$CLAUDE_DIR/hq"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

ARCHIVE_PATH=""
WORKTREES=()
TEAMS=()
KEEP_BRANCHES=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)        ARCHIVE_PATH="$2"; shift 2 ;;
    --worktrees)      IFS=',' read -ra WORKTREES <<< "$2"; shift 2 ;;
    --teams)          IFS=',' read -ra TEAMS <<< "$2"; shift 2 ;;
    --keep-branches)  KEEP_BRANCHES=true; shift ;;
    --dry-run)        DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *) echo "Error: unknown option '$1'" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Load from manifest if --archive given
# ---------------------------------------------------------------------------

if [[ -n "$ARCHIVE_PATH" ]]; then
  MANIFEST="$ARCHIVE_PATH/manifest.json"
  if [[ ! -f "$MANIFEST" ]]; then
    echo "Error: manifest.json not found in $ARCHIVE_PATH" >&2
    echo "Archive may be incomplete. Refusing to clean up without manifest." >&2
    exit 1
  fi

  echo "Reading manifest from $MANIFEST"

  # Extract worktree paths from manifest
  if [[ ${#WORKTREES[@]} -eq 0 ]]; then
    while IFS= read -r path; do
      [[ -n "$path" ]] && WORKTREES+=("$path")
    done < <(python3 -c "
import json
with open('$MANIFEST') as f:
    m = json.load(f)
for wt in m.get('worktrees', []):
    path = wt.get('path', '')
    if path:
        print(path)
" 2>/dev/null || true)
  fi

  # Extract teams from manifest
  if [[ ${#TEAMS[@]} -eq 0 ]]; then
    while IFS= read -r team; do
      [[ -n "$team" ]] && TEAMS+=("$team")
    done < <(python3 -c "
import json
with open('$MANIFEST') as f:
    m = json.load(f)
for t in m.get('teams', []):
    print(t)
" 2>/dev/null || true)
  fi
fi

if [[ ${#WORKTREES[@]} -eq 0 && ${#TEAMS[@]} -eq 0 ]]; then
  echo "Nothing to clean up (no worktrees or teams specified)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Helper: path mangling
# ---------------------------------------------------------------------------

path_to_project_dir() {
  local p="$1"
  p="${p%/}"
  echo "$p" | sed 's|/|-|g'
}

main_worktree() {
  git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //'
}

MAIN_WT="$(main_worktree)"

# ---------------------------------------------------------------------------
# Dry-run prefix
# ---------------------------------------------------------------------------

run_cmd() {
  if $DRY_RUN; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# 1. Remove git worktrees and branches
# ---------------------------------------------------------------------------

echo ""
echo "=== Removing worktrees ==="
for wt_path in "${WORKTREES[@]+"${WORKTREES[@]}"}"; do
  # Skip main worktree
  if [[ "$wt_path" == "$MAIN_WT" ]]; then
    echo "  Skipping main worktree: $wt_path"
    continue
  fi

  if [[ ! -d "$wt_path" ]]; then
    echo "  Skipping (already gone): $wt_path"
    continue
  fi

  # Get branch name before removal
  local_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null || true)

  echo "  Removing worktree: $wt_path"
  run_cmd git worktree remove --force "$wt_path" 2>/dev/null || \
    echo "  Warning: failed to remove worktree $wt_path (may already be removed)"

  # Delete branch
  if [[ -n "$local_branch" ]] && ! $KEEP_BRANCHES; then
    echo "  Deleting branch: $local_branch"
    run_cmd git branch -D "$local_branch" 2>/dev/null || \
      echo "  Warning: failed to delete branch $local_branch"
  fi
done

# ---------------------------------------------------------------------------
# 2. Remove Claude project dirs
# ---------------------------------------------------------------------------

echo ""
echo "=== Removing Claude project dirs ==="
for wt_path in "${WORKTREES[@]+"${WORKTREES[@]}"}"; do
  # Skip main worktree
  [[ "$wt_path" == "$MAIN_WT" ]] && continue

  project_dir_name=$(path_to_project_dir "$wt_path")
  project_dir="$CLAUDE_DIR/projects/$project_dir_name"

  if [[ -d "$project_dir" ]]; then
    echo "  Removing: $project_dir"
    run_cmd rm -rf "$project_dir"
  fi
done

# ---------------------------------------------------------------------------
# 3. Remove team dirs
# ---------------------------------------------------------------------------

echo ""
echo "=== Removing team dirs ==="
for team in "${TEAMS[@]+"${TEAMS[@]}"}"; do
  # Never remove HQ team here — only if explicitly listed
  team_dir="$CLAUDE_DIR/teams/$team"
  if [[ -d "$team_dir" ]]; then
    echo "  Removing team: $team"
    run_cmd rm -rf "$team_dir"
  fi

  # Remove task dir too
  task_dir="$CLAUDE_DIR/tasks/$team"
  if [[ -d "$task_dir" ]]; then
    echo "  Removing tasks: $team"
    run_cmd rm -rf "$task_dir"
  fi
done

# ---------------------------------------------------------------------------
# 4. Remove HQ worktree status files
# ---------------------------------------------------------------------------

echo ""
echo "=== Removing HQ worktree status files ==="
if [[ -d "$HQ_DIR/worktrees" ]]; then
  for wt_path in "${WORKTREES[@]+"${WORKTREES[@]}"}"; do
    [[ "$wt_path" == "$MAIN_WT" ]] && continue
    local_branch=$(python3 -c "
import json, glob, os
for f in glob.glob(os.path.expanduser('$HQ_DIR/worktrees/*.json')):
    try:
        d = json.load(open(f))
        wp = d.get('worktree_path', d.get('worktree', ''))
        if wp == '$wt_path':
            print(os.path.basename(f))
    except: pass
" 2>/dev/null || true)
    if [[ -n "$local_branch" ]]; then
      echo "  Removing HQ status: $local_branch"
      run_cmd rm -f "$HQ_DIR/worktrees/$local_branch"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 5. Prune worktrees
# ---------------------------------------------------------------------------

echo ""
echo "=== Pruning stale worktree references ==="
run_cmd git worktree prune 2>/dev/null || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "=== Cleanup complete ==="
echo "  Worktrees removed: ${#WORKTREES[@]} (excl. main)"
echo "  Teams removed: ${#TEAMS[@]}"
if $KEEP_BRANCHES; then
  echo "  Branches: kept (--keep-branches)"
fi
if [[ -n "$ARCHIVE_PATH" ]]; then
  echo "  Archive preserved at: $ARCHIVE_PATH"
fi
