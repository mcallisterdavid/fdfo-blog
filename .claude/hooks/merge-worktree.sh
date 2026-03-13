#!/usr/bin/env bash
# merge-worktree.sh — Execute merge or cherry-pick across git worktrees.
#
# Used by the HQ director to integrate branches from child worktrees
# into the effective mainline. Guarantees the target worktree is never
# left in a dirty state — all operations abort cleanly on conflict.
#
# Usage:
#   bash .claude/hooks/merge-worktree.sh \
#     --source-branch <branch> --target-branch <branch> \
#     --target-worktree <path> \
#     [--merge-type merge|cherry-pick] [--commits <h1,h2,...>] \
#     [--expected-head <commit>] [--dry-run] [--no-ff]
#
# Exit codes:
#   0 — success (or nothing to merge)
#   1 — pre-flight failure (dirty tree, missing branch, stale HEAD)
#   2 — conflict (merge aborted cleanly)
#
# Examples:
#   bash .claude/hooks/merge-worktree.sh \
#     --source-branch fish-fast-humanoid --target-branch fish \
#     --target-worktree /home/user/FAR-cmk-test.fish --dry-run
#
#   bash .claude/hooks/merge-worktree.sh \
#     --source-branch fish-fast-humanoid --target-branch fish \
#     --target-worktree /home/user/FAR-cmk-test.fish \
#     --expected-head abc1234
#
#   bash .claude/hooks/merge-worktree.sh \
#     --source-branch fish-hlgauss --target-branch fish \
#     --target-worktree /home/user/FAR-cmk-test.fish \
#     --merge-type cherry-pick --commits abc123,def456

set -euo pipefail

SOURCE_BRANCH=""
TARGET_BRANCH=""
TARGET_WORKTREE=""
MERGE_TYPE="merge"
COMMITS=""
EXPECTED_HEAD=""
DRY_RUN=false
NO_FF=true  # default: always create merge commit

HQ_DIR="$HOME/.claude/hq"
LOG_FILE="${HQ_DIR}/merge-log.jsonl"

usage() {
  echo "Usage: $0 --source-branch <branch> --target-branch <branch> --target-worktree <path> [options]" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "  --merge-type merge|cherry-pick   Type of integration (default: merge)" >&2
  echo "  --commits <h1,h2,...>            Commits to cherry-pick (required for cherry-pick)" >&2
  echo "  --expected-head <commit>         Abort if source HEAD doesn't match (race guard)" >&2
  echo "  --dry-run                        Preview merge without executing" >&2
  echo "  --no-ff                          Force merge commit (default: true)" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-branch)   SOURCE_BRANCH="$2"; shift 2 ;;
    --target-branch)   TARGET_BRANCH="$2"; shift 2 ;;
    --target-worktree) TARGET_WORKTREE="$2"; shift 2 ;;
    --merge-type)      MERGE_TYPE="$2"; shift 2 ;;
    --commits)         COMMITS="$2"; shift 2 ;;
    --expected-head)   EXPECTED_HEAD="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=true; shift ;;
    --no-ff)           NO_FF=true; shift ;;
    -h|--help)         usage ;;
    -*)                echo "Unknown option: $1" >&2; usage ;;
    *)                 echo "Unexpected argument: $1" >&2; usage ;;
  esac
done

if [[ -z "$SOURCE_BRANCH" ]]; then
  echo "Error: --source-branch is required." >&2
  usage
fi
if [[ -z "$TARGET_BRANCH" ]]; then
  echo "Error: --target-branch is required." >&2
  usage
fi
if [[ -z "$TARGET_WORKTREE" ]]; then
  echo "Error: --target-worktree is required." >&2
  usage
fi
if [[ "$MERGE_TYPE" == "cherry-pick" && -z "$COMMITS" ]]; then
  echo "Error: --commits is required for cherry-pick." >&2
  usage
fi

# Helper: log a merge operation to merge-log.jsonl
log_merge() {
  local action="$1" status="$2" source_commit="$3" result_commit="$4" conflicts="$5"
  mkdir -p "$HQ_DIR"
  local TIMESTAMP
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

  python3 -c "
import json, sys, fcntl

entry = {
    'timestamp': sys.argv[1],
    'action': sys.argv[2],
    'source_branch': sys.argv[3],
    'target_branch': sys.argv[4],
    'source_commit': sys.argv[5],
    'result_commit': sys.argv[6] if sys.argv[6] != 'null' else None,
    'status': sys.argv[7],
    'conflicts': json.loads(sys.argv[8]) if sys.argv[8] else [],
    'rollback_commit': sys.argv[9] if sys.argv[9] != 'null' else None,
}

log_file = sys.argv[10]
with open(log_file, 'a') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.write(json.dumps(entry) + '\n')
    fcntl.flock(f, fcntl.LOCK_UN)
" "$TIMESTAMP" "$action" "$SOURCE_BRANCH" "$TARGET_BRANCH" \
  "$source_commit" "$result_commit" "$status" "$conflicts" \
  "${ROLLBACK_COMMIT:-null}" "$LOG_FILE"
}

# --- Phase 1: Pre-flight checks ---

if [[ ! -d "$TARGET_WORKTREE" ]]; then
  echo "Error: target worktree does not exist: $TARGET_WORKTREE" >&2
  exit 1
fi

# Check clean working tree
DIRTY=$(git -C "$TARGET_WORKTREE" status --porcelain 2>/dev/null)
if [[ -n "$DIRTY" ]]; then
  echo "Error: target worktree has uncommitted changes:" >&2
  echo "$DIRTY" >&2
  exit 1
fi

# Record rollback point
ROLLBACK_COMMIT=$(git -C "$TARGET_WORKTREE" rev-parse HEAD)

# Verify source branch exists
if ! git -C "$TARGET_WORKTREE" rev-parse --verify "$SOURCE_BRANCH" >/dev/null 2>&1; then
  echo "Error: source branch does not exist: $SOURCE_BRANCH" >&2
  exit 1
fi

# Race guard: verify source HEAD matches expectation
SOURCE_HEAD=$(git -C "$TARGET_WORKTREE" rev-parse "$SOURCE_BRANCH")
if [[ -n "$EXPECTED_HEAD" ]]; then
  SHORT_EXPECTED="${EXPECTED_HEAD:0:7}"
  SHORT_ACTUAL="${SOURCE_HEAD:0:7}"
  if [[ "$SOURCE_HEAD" != "$EXPECTED_HEAD" && ! "$SOURCE_HEAD" =~ ^"$EXPECTED_HEAD" ]]; then
    echo "Error: source branch HEAD has moved since dry-run." >&2
    echo "  Expected: $SHORT_EXPECTED" >&2
    echo "  Actual:   $SHORT_ACTUAL" >&2
    exit 1
  fi
fi

# --- Phase 2: Analysis ---

AHEAD=$(git -C "$TARGET_WORKTREE" rev-list --count "${TARGET_BRANCH}..${SOURCE_BRANCH}" 2>/dev/null || echo 0)
BEHIND=$(git -C "$TARGET_WORKTREE" rev-list --count "${SOURCE_BRANCH}..${TARGET_BRANCH}" 2>/dev/null || echo 0)

if [[ "$MERGE_TYPE" == "merge" && "$AHEAD" -eq 0 ]]; then
  echo "Nothing to merge: $SOURCE_BRANCH is behind or equal to $TARGET_BRANCH."
  exit 0
fi

echo "Source: $SOURCE_BRANCH (HEAD: ${SOURCE_HEAD:0:7})"
echo "Target: $TARGET_BRANCH (in $TARGET_WORKTREE)"
echo "Divergence: $AHEAD commits ahead, $BEHIND commits behind"
echo "SOURCE_HEAD=${SOURCE_HEAD}"  # Machine-readable for --expected-head

if [[ "$MERGE_TYPE" == "merge" ]]; then
  echo ""
  echo "Commits to merge:"
  git -C "$TARGET_WORKTREE" log --oneline "${TARGET_BRANCH}..${SOURCE_BRANCH}"
fi

# --- Phase 3: Execute ---

if [[ "$MERGE_TYPE" == "merge" ]]; then
  # --- Full merge ---
  if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "=== DRY RUN ==="
    if git -C "$TARGET_WORKTREE" merge --no-commit --no-ff "$SOURCE_BRANCH" >/dev/null 2>&1; then
      echo "Dry run: merge would succeed cleanly."
      git -C "$TARGET_WORKTREE" merge --abort 2>/dev/null || true
      exit 0
    else
      CONFLICT_FILES=$(git -C "$TARGET_WORKTREE" diff --name-only --diff-filter=U 2>/dev/null || echo "(unknown)")
      git -C "$TARGET_WORKTREE" merge --abort 2>/dev/null || true
      echo "Dry run: merge would have CONFLICTS in:" >&2
      echo "$CONFLICT_FILES" >&2
      exit 2
    fi
  fi

  # Real merge
  MERGE_FLAGS="--no-ff"
  MERGE_MSG="Merge ${SOURCE_BRANCH} into ${TARGET_BRANCH} (director merge)"

  if git -C "$TARGET_WORKTREE" merge $MERGE_FLAGS -m "$MERGE_MSG" "$SOURCE_BRANCH" 2>/dev/null; then
    RESULT_COMMIT=$(git -C "$TARGET_WORKTREE" rev-parse HEAD)
    log_merge "merge" "success" "$SOURCE_HEAD" "$RESULT_COMMIT" "[]"
    echo ""
    echo "SUCCESS: merged $SOURCE_BRANCH into $TARGET_BRANCH at ${RESULT_COMMIT:0:7}"
    exit 0
  else
    CONFLICT_FILES=$(git -C "$TARGET_WORKTREE" diff --name-only --diff-filter=U 2>/dev/null || echo "")
    CONFLICT_JSON="[]"
    if [[ -n "$CONFLICT_FILES" ]]; then
      CONFLICT_JSON=$(echo "$CONFLICT_FILES" | python3 -c "import json, sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
    fi
    git -C "$TARGET_WORKTREE" merge --abort 2>/dev/null || true
    log_merge "merge" "conflict" "$SOURCE_HEAD" "null" "$CONFLICT_JSON"
    echo ""
    echo "CONFLICT: merge aborted. Conflicting files:" >&2
    echo "$CONFLICT_FILES" >&2
    echo "Rollback commit: ${ROLLBACK_COMMIT:0:7}" >&2
    exit 2
  fi

elif [[ "$MERGE_TYPE" == "cherry-pick" ]]; then
  # --- Cherry-pick ---
  IFS=',' read -ra COMMIT_LIST <<< "$COMMITS"

  if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "=== DRY RUN (cherry-pick) ==="
    ALL_OK=true
    for commit in "${COMMIT_LIST[@]}"; do
      if ! git -C "$TARGET_WORKTREE" cherry-pick --no-commit "$commit" >/dev/null 2>&1; then
        echo "Dry run: cherry-pick of $commit would CONFLICT." >&2
        ALL_OK=false
        break
      fi
    done
    # Reset regardless
    git -C "$TARGET_WORKTREE" reset --hard "$ROLLBACK_COMMIT" >/dev/null 2>&1
    if [[ "$ALL_OK" == true ]]; then
      echo "Dry run: all ${#COMMIT_LIST[@]} cherry-picks would succeed."
      exit 0
    else
      exit 2
    fi
  fi

  # Real cherry-pick
  for commit in "${COMMIT_LIST[@]}"; do
    if ! git -C "$TARGET_WORKTREE" cherry-pick "$commit" 2>/dev/null; then
      git -C "$TARGET_WORKTREE" cherry-pick --abort 2>/dev/null || true
      git -C "$TARGET_WORKTREE" reset --hard "$ROLLBACK_COMMIT" >/dev/null 2>&1
      log_merge "cherry-pick" "conflict" "$commit" "null" "[]"
      echo ""
      echo "CONFLICT: cherry-pick of $commit failed. All cherry-picks aborted." >&2
      echo "Rollback commit: ${ROLLBACK_COMMIT:0:7}" >&2
      exit 2
    fi
  done

  RESULT_COMMIT=$(git -C "$TARGET_WORKTREE" rev-parse HEAD)
  log_merge "cherry-pick" "success" "${COMMIT_LIST[-1]}" "$RESULT_COMMIT" "[]"
  echo ""
  echo "SUCCESS: cherry-picked ${#COMMIT_LIST[@]} commit(s) into $TARGET_BRANCH at ${RESULT_COMMIT:0:7}"
  exit 0

else
  echo "Error: unknown merge-type: $MERGE_TYPE" >&2
  exit 1
fi
