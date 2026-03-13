#!/usr/bin/env bash
# archive-session.sh — Archive all data for a director session.
#
# Usage:
#   archive-session.sh --name <session-name> [--worktrees <path1,path2,...>] [--teams <t1,t2,...>]
#   archive-session.sh --name <session-name> --all   # auto-discover from HQ state + git worktree list
#
# Archive location: ~/.claude/archives/<YYYYMMDD>-<session-name>/

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
HQ_DIR="$CLAUDE_DIR/hq"
ARCHIVES_DIR="$CLAUDE_DIR/archives"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

NAME=""
WORKTREES=()
TEAMS=()
AUTO_DISCOVER=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)       NAME="$2"; shift 2 ;;
    --worktrees)  IFS=',' read -ra WORKTREES <<< "$2"; shift 2 ;;
    --teams)      IFS=',' read -ra TEAMS <<< "$2"; shift 2 ;;
    --all)        AUTO_DISCOVER=true; shift ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *) echo "Error: unknown option '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo "Error: --name is required" >&2
  exit 1
fi

DATE=$(date +%Y%m%d)
ARCHIVE_DIR="$ARCHIVES_DIR/${DATE}-${NAME}"

# ---------------------------------------------------------------------------
# Auto-discovery
# ---------------------------------------------------------------------------

main_worktree() {
  git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //'
}

if $AUTO_DISCOVER; then
  MAIN_WT="$(main_worktree)"

  # Discover worktrees from HQ state files
  if [[ -d "$HQ_DIR/worktrees" ]]; then
    for f in "$HQ_DIR/worktrees"/*.json; do
      [[ -f "$f" ]] || continue
      # Extract worktree path from the JSON
      wt_path=$(python3 -c "import json,sys; d=json.load(open('$f')); print(d.get('worktree_path', d.get('worktree', '')))" 2>/dev/null || true)
      if [[ -n "$wt_path" && -d "$wt_path" ]]; then
        WORKTREES+=("$wt_path")
      fi
      # Extract team name
      team=$(python3 -c "import json,sys; d=json.load(open('$f')); print(d.get('team_name', ''))" 2>/dev/null || true)
      if [[ -n "$team" ]]; then
        TEAMS+=("$team")
      fi
    done
  fi

  # Also discover from git worktree list (catch any not in HQ state)
  while IFS= read -r line; do
    wt_path=$(echo "$line" | awk '{print $1}')
    # Skip main worktree
    [[ "$wt_path" == "$MAIN_WT" ]] && continue
    # Skip bare worktrees
    [[ "$line" == *"(bare)"* ]] && continue
    # Add if not already in list
    local_found=false
    for existing in "${WORKTREES[@]+"${WORKTREES[@]}"}"; do
      [[ "$existing" == "$wt_path" ]] && local_found=true
    done
    $local_found || WORKTREES+=("$wt_path")
  done < <(git worktree list 2>/dev/null || true)

  # Discover teams from ~/.claude/teams/ that aren't "hq"
  if [[ -d "$CLAUDE_DIR/teams" ]]; then
    for team_dir in "$CLAUDE_DIR/teams"/*/; do
      [[ -d "$team_dir" ]] || continue
      team_name=$(basename "$team_dir")
      [[ "$team_name" == "hq" ]] && continue
      # Add if not already in list
      local_found=false
      for existing in "${TEAMS[@]+"${TEAMS[@]}"}"; do
        [[ "$existing" == "$team_name" ]] && local_found=true
      done
      $local_found || TEAMS+=("$team_name")
    done
  fi
fi

# ---------------------------------------------------------------------------
# Helper: path mangling (worktree path -> Claude project dir name)
# /Users/imcallid/gh_personal/fdfo-blog-viz -> -Users-imcallid-gh_personal-fdfo-blog-viz
# ---------------------------------------------------------------------------

path_to_project_dir() {
  local p="$1"
  # Remove trailing slash, replace / with -
  # Claude project dirs use leading dash: /Users/foo/bar -> -Users-foo-bar
  p="${p%/}"
  echo "$p" | sed 's|/|-|g'
}

# ---------------------------------------------------------------------------
# Create archive structure
# ---------------------------------------------------------------------------

if [[ -d "$ARCHIVE_DIR" ]]; then
  echo "Warning: archive directory already exists: $ARCHIVE_DIR"
  echo "Appending to existing archive."
fi

mkdir -p "$ARCHIVE_DIR"/{conversations,teams,tasks,hq,patches}

echo "Archiving session '$NAME' to $ARCHIVE_DIR"
echo "  Worktrees: ${WORKTREES[*]+"${WORKTREES[*]}"}"
echo "  Teams: ${TEAMS[*]+"${TEAMS[*]}"}"

# ---------------------------------------------------------------------------
# 1. Archive conversation logs (per-worktree)
# ---------------------------------------------------------------------------

archive_conversations() {
  local wt_path="$1"
  local wt_name
  wt_name=$(basename "$wt_path")
  local project_dir_name
  project_dir_name=$(path_to_project_dir "$wt_path")
  local src_dir="$CLAUDE_DIR/projects/$project_dir_name"

  if [[ -d "$src_dir" ]]; then
    local dest="$ARCHIVE_DIR/conversations/$wt_name"
    if [[ -d "$dest" ]]; then
      echo "  Skipping conversations for $wt_name (already archived)"
      return
    fi
    mkdir -p "$dest"
    # Copy all JSONL files (conversation logs + subagent logs)
    find "$src_dir" -maxdepth 1 -name "*.jsonl" -exec cp {} "$dest/" \; 2>/dev/null || true
    # Copy memory files too
    if [[ -d "$src_dir/memory" ]]; then
      cp -r "$src_dir/memory" "$dest/memory" 2>/dev/null || true
    fi
    local count
    count=$(find "$dest" -name "*.jsonl" 2>/dev/null | wc -l)
    echo "  Archived $count conversation files for $wt_name"
  else
    echo "  No conversation data found for $wt_name (looked in $src_dir)"
  fi
}

echo ""
echo "=== Archiving conversations ==="
for wt in "${WORKTREES[@]+"${WORKTREES[@]}"}"; do
  archive_conversations "$wt"
done

# Also archive main worktree conversations
MAIN_WT="$(main_worktree)"
if [[ -n "$MAIN_WT" ]]; then
  archive_conversations "$MAIN_WT"
fi

# ---------------------------------------------------------------------------
# 2. Archive team configs and inboxes
# ---------------------------------------------------------------------------

echo ""
echo "=== Archiving teams ==="
for team in "${TEAMS[@]+"${TEAMS[@]}"}"; do
  src="$CLAUDE_DIR/teams/$team"
  if [[ -d "$src" ]]; then
    dest="$ARCHIVE_DIR/teams/$team"
    if [[ -d "$dest" ]]; then
      echo "  Skipping team $team (already archived)"
      continue
    fi
    cp -r "$src" "$dest"
    echo "  Archived team: $team"
  else
    echo "  Warning: team directory not found: $src"
  fi
done

# Always archive HQ team if it exists
if [[ -d "$CLAUDE_DIR/teams/hq" ]]; then
  dest="$ARCHIVE_DIR/teams/hq"
  if [[ ! -d "$dest" ]]; then
    cp -r "$CLAUDE_DIR/teams/hq" "$dest"
    echo "  Archived team: hq"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Archive task lists
# ---------------------------------------------------------------------------

echo ""
echo "=== Archiving tasks ==="
for team in "${TEAMS[@]+"${TEAMS[@]}"}"; do
  src="$CLAUDE_DIR/tasks/$team"
  if [[ -d "$src" ]]; then
    dest="$ARCHIVE_DIR/tasks/$team"
    if [[ -d "$dest" ]]; then
      echo "  Skipping tasks for $team (already archived)"
      continue
    fi
    cp -r "$src" "$dest"
    echo "  Archived tasks: $team"
  else
    echo "  No task list for team: $team"
  fi
done

# HQ tasks too
if [[ -d "$CLAUDE_DIR/tasks/hq" ]]; then
  dest="$ARCHIVE_DIR/tasks/hq"
  if [[ ! -d "$dest" ]]; then
    cp -r "$CLAUDE_DIR/tasks/hq" "$dest"
    echo "  Archived tasks: hq"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Archive HQ state
# ---------------------------------------------------------------------------

echo ""
echo "=== Archiving HQ state ==="
if [[ -d "$HQ_DIR" ]]; then
  # Copy everything in HQ dir
  cp -r "$HQ_DIR"/* "$ARCHIVE_DIR/hq/" 2>/dev/null || true
  echo "  Archived HQ state"
else
  echo "  No HQ state found"
fi

# ---------------------------------------------------------------------------
# 5. Archive federation log
# ---------------------------------------------------------------------------

if [[ -f "$CLAUDE_DIR/federation/message-log.jsonl" ]]; then
  cp "$CLAUDE_DIR/federation/message-log.jsonl" "$ARCHIVE_DIR/hq/federation-message-log.jsonl"
  echo "  Archived federation message log"
fi

# ---------------------------------------------------------------------------
# 6. Git patches for dirty worktrees + branch metadata
# ---------------------------------------------------------------------------

echo ""
echo "=== Archiving git state ==="
BRANCHES_FILE="$ARCHIVE_DIR/branches.txt"
: > "$BRANCHES_FILE"

archive_git_state() {
  local wt_path="$1"
  local wt_name
  wt_name=$(basename "$wt_path")

  if [[ ! -d "$wt_path/.git" && ! -f "$wt_path/.git" ]]; then
    echo "  Skipping $wt_name (not a git worktree)"
    return
  fi

  # Branch and SHA
  local branch sha
  branch=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "(detached)")
  sha=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null || echo "unknown")
  echo "$branch $sha $wt_path" >> "$BRANCHES_FILE"

  # Check for uncommitted changes
  local status
  status=$(git -C "$wt_path" status --porcelain 2>/dev/null || true)
  if [[ -n "$status" ]]; then
    # Save status
    echo "$status" > "$ARCHIVE_DIR/patches/${wt_name}-status.txt"

    # Save tracked changes as patch
    local diff
    diff=$(git -C "$wt_path" diff HEAD 2>/dev/null || true)
    if [[ -n "$diff" ]]; then
      echo "$diff" > "$ARCHIVE_DIR/patches/${wt_name}-tracked.patch"
      echo "  Saved patch for $wt_name (tracked changes)"
    fi

    # Save untracked files: list + tarball of actual content
    local untracked
    untracked=$(git -C "$wt_path" ls-files --others --exclude-standard 2>/dev/null || true)
    if [[ -n "$untracked" ]]; then
      echo "$untracked" > "$ARCHIVE_DIR/patches/${wt_name}-untracked.txt"
      # Archive actual untracked files (skip large binaries >50MB)
      local untracked_archive="$ARCHIVE_DIR/patches/${wt_name}-untracked.tar.gz"
      local filtered_files
      filtered_files=$(cd "$wt_path" && echo "$untracked" | while IFS= read -r f; do
        if [[ -f "$f" ]]; then
          local size
          size=$(stat --format=%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
          if [[ "$size" -lt 52428800 ]]; then  # 50MB
            echo "$f"
          fi
        fi
      done)
      if [[ -n "$filtered_files" ]]; then
        (cd "$wt_path" && echo "$filtered_files" | tar czf "$untracked_archive" -T - 2>/dev/null) || true
        local tar_size
        tar_size=$(du -sh "$untracked_archive" 2>/dev/null | cut -f1)
        echo "  Archived untracked files for $wt_name ($tar_size)"
      else
        echo "  Saved untracked file list for $wt_name (no files small enough to tar)"
      fi
    fi
  fi
}

for wt in "${WORKTREES[@]+"${WORKTREES[@]}"}"; do
  archive_git_state "$wt"
done
# Also archive main worktree git state
archive_git_state "$MAIN_WT"

echo "  Branch mapping saved to branches.txt"

# ---------------------------------------------------------------------------
# 7. Write manifest
# ---------------------------------------------------------------------------

echo ""
echo "=== Writing manifest ==="

# Calculate total archive size
TOTAL_SIZE=$(du -sh "$ARCHIVE_DIR" 2>/dev/null | cut -f1)

# Build manifest JSON
python3 -c "
import json, os, datetime

manifest = {
    'name': '$NAME',
    'date': '$(date -Iseconds)',
    'archive_path': '$ARCHIVE_DIR',
    'total_size': '$TOTAL_SIZE',
    'worktrees': [],
    'teams': [],
}

# Worktree info
branches_file = '$BRANCHES_FILE'
if os.path.exists(branches_file):
    with open(branches_file) as f:
        for line in f:
            parts = line.strip().split(' ', 2)
            if len(parts) >= 2:
                manifest['worktrees'].append({
                    'branch': parts[0],
                    'sha': parts[1],
                    'path': parts[2] if len(parts) > 2 else '',
                })

# Teams
teams_dir = '$ARCHIVE_DIR/teams'
if os.path.isdir(teams_dir):
    manifest['teams'] = sorted(os.listdir(teams_dir))

# Conversation counts
convos_dir = '$ARCHIVE_DIR/conversations'
if os.path.isdir(convos_dir):
    manifest['conversation_dirs'] = sorted(os.listdir(convos_dir))

# Patch counts
patches_dir = '$ARCHIVE_DIR/patches'
if os.path.isdir(patches_dir):
    patches = [f for f in os.listdir(patches_dir) if f.endswith('.patch')]
    manifest['dirty_worktrees'] = len(patches)

with open('$ARCHIVE_DIR/manifest.json', 'w') as f:
    json.dump(manifest, f, indent=2)
"

echo "  Manifest written to $ARCHIVE_DIR/manifest.json"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "=== Archive complete ==="
echo "  Location: $ARCHIVE_DIR"
echo "  Size: $TOTAL_SIZE"
echo "  Worktrees: ${#WORKTREES[@]}"
echo "  Teams: ${#TEAMS[@]}"
echo ""
echo "To clean up after archiving:"
echo "  bash .claude/hooks/cleanup-session.sh --archive $ARCHIVE_DIR"
