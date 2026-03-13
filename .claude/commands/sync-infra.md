---
allowed-tools: Bash(git *), Bash(rsync *), Bash(diff *), Bash(ls *), Bash(cp *), Bash(rm *), Bash(mkdir *), Read, Write, Edit, Glob, Grep, Task, AskUserQuestion
description: Sync .claude/, docs/, CLAUDE.md across worktrees — LLM-judged per-file decisions
---

# Sync: Cross-Worktree Infrastructure Sync

You synchronize shared infrastructure files (`.claude/`, `docs/`, `CLAUDE.md`) from a source worktree to one or more target worktrees. Instead of a static manifest, you **read and judge** each difference to decide the right action.

## Step 1: Parse Arguments

Extract from `$ARGUMENTS`:

- **Source worktree**: defaults to the current worktree
- **Target**: a specific worktree name, or `--all` for all worktrees
- **Mode**: `--dry-run` (default — show plan only) or `--apply` (execute the plan)
- **Scope**: `--scope .claude` or `--scope docs` to limit to one directory (default: all three — `.claude/`, `docs/`, `CLAUDE.md`)
- **Exclude worktrees**: `--skip <name1,name2>` to exclude specific worktrees

If no arguments provided, default to `--dry-run --all` from the current worktree.

## Step 2: Discover Worktrees

Run `git worktree list` to get all worktrees. Filter out:
- The source worktree itself
- Any worktrees specified in `--skip`

Display the list of target worktrees and confirm with the user before proceeding.

## Step 3: Diff Each Target

For each target worktree, compare the sync scope between source and target:

```bash
diff -rq <source>/.claude/ <target>/.claude/ --exclude='settings.local.json'
diff -rq <source>/docs/ <target>/docs/
diff <source>/CLAUDE.md <target>/CLAUDE.md
```

Categorize each difference into one of:

### Categories

1. **COPY** — File exists in source but not in target. Action: copy it over.
2. **OVERWRITE** — File exists in both, target is simply an older version of source. Action: overwrite target with source.
3. **MERGE** — File exists in both, but the target has unique content not in source (branch-specific findings, experiment notes). Action: intelligently merge — keep the target's unique additions while updating shared content from source.
4. **PROPAGATE BACK** — File exists in target but not in source. New content created in the feature branch. Action: offer to copy it back to source.
5. **DELETE (ghost)** — File exists in target but was intentionally removed/consolidated in source. Action: offer to delete from target.
6. **SKIP** — File is intentionally worktree-specific. Action: leave it alone.

### How to Judge

For each differing file, **read both versions** (source and target). Then decide:

- If the target version is a strict prefix/subset of the source version -> **OVERWRITE**
- If the target has lines/sections not present in source that look like branch-specific findings -> **MERGE**
- If the file only exists in the target and looks like an investigation report -> **PROPAGATE BACK**
- If the file was consolidated into another file on source -> **DELETE (ghost)** — verify the replacement file exists
- If the file is `settings.local.json` or under a known per-worktree path -> **SKIP**

**Always-skip list** (never touch these):
- `.claude/settings.local.json`
- Any file under `notebook/` where both versions exist but differ (each branch's version is authoritative for its own experiments)

**Always-overwrite list** (pure infrastructure, no branch-specific content expected):
- `.claude/hooks/*`
- `.claude/commands/*`
- `.claude/agents/*`
- `.claude/settings.json`

For everything else, read and judge.

## Step 4: Present the Plan

For each target worktree, display a table:

```
=== fdfo-blog-viz ===
ACTION          FILE                                    REASON
OVERWRITE       .claude/commands/hq.md                  target is older version
OVERWRITE       CLAUDE.md                               target missing new sections
MERGE           docs/experiment-checklist.md            target has unique lessons
COPY            docs/architecture.md                    missing in target
PROPAGATE BACK  notebook/insights.md                    new findings, not in source
SKIP            .claude/settings.local.json             worktree-specific
---
5 changes, 1 merge, 1 propagate-back, 1 skip
```

If `--dry-run` (default), stop here and show the plan. Ask the user:
- "Apply this plan?" (proceed to Step 5)
- "Adjust?" (let user modify)
- "Apply to specific worktrees only?" (subset)

## Step 5: Apply (only if --apply or user approved)

### COPY / OVERWRITE
```bash
cp <source>/<file> <target>/<file>
```

### MERGE
Read both versions. Produce a merged version that takes the source as base and inserts the target's unique sections in the appropriate location. Show the user the merge result for confirmation if the file is important (like CLAUDE.md).

### PROPAGATE BACK
```bash
cp <target>/<file> <source>/<file>
```
Stage and note for commit on the source branch.

### DELETE (ghost)
```bash
rm <target>/<file>
```
Only after confirming the replacement file exists in the target.

### Commit per worktree
After applying all changes to a target worktree:
```bash
cd <target> && git add -A .claude/ docs/ CLAUDE.md && git commit -m "Sync infrastructure from <source-branch>"
```

**Push is NOT automatic.** Tell the user which branches have new commits and let them decide when to push.

## Step 6: Summary

Display a final summary:
```
Sync complete:
  fdfo-blog-viz: 5 files updated, 1 merged, 1 propagated back
  fdfo-blog-prose: 3 files updated
  ...

Unpushed branches: fdfo-blog-viz, fdfo-blog-prose
```

## Design Principles

- **Judgment over rules**: Read files and decide, don't rely on a static list
- **Dry-run by default**: Never modify anything without showing the plan first
- **Source is canonical**: When in doubt, source wins. Exception: files with clear branch-specific additions.
- **Additive propagation**: New files flow back to source. Existing files are never overwritten on source.
- **One commit per worktree**: Clean git history, easy to revert
- **No manifest maintenance**: The skill figures it out each time
