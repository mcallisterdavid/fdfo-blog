---
allowed-tools: Bash(bash *), Read, Glob, Grep
description: HQ coordination — director issues directives and manages merges; team leads report status and merge readiness
---

# HQ: Hierarchical Cross-Worktree Coordination

You are participating in a **pyramid coordination system**. A single **director** running in the main worktree coordinates all team leads across worktrees. All cross-team information flows through the director — no direct lead-to-lead messaging.

## Role Detection

Determine your role:
- Read `~/.claude/hq/config.json`. If it exists and its `team_name` matches your current team context, you are the **director**.
- Otherwise, you are a **team lead**.

## Constraints (STRICT)

- **No peer-to-peer messaging**: Team leads never message other team leads directly. All cross-team info routes through the director.
- **Director is purely managerial**: No code changes (except git merge ops).
- **Team leads must check inbox**: Check `/hq inbox` at every phase transition, after every report-writer summary, and before reporting merge-ready.
- **Batch findings**: Compile multiple findings into one report. Don't send N reports with N findings.
- **Reference files, not inline data**: Keep messages short. Point to `notebook/*.md`, W&B URLs, or commit hashes.

## Step 1: Parse Subcommand

Extract the subcommand from `$ARGUMENTS`:

### Director Subcommands

| Subcommand | Usage |
|-----------|-------|
| `status` | `/hq status` |
| `launch <worktree> --name <short> --mission <text>` | `/hq launch ../fdfo-blog-viz --name viz-team --mission "Build interactive visualizations"` |
| `send <team> <message>` | `/hq send feat-team "Prioritize recon_error metric"` |
| `send <team> --high <message>` | `/hq send feat-team --high "Stop runs immediately"` |
| `broadcast <message>` | `/hq broadcast "New baseline merged into mainline"` |
| `broadcast --only <t1,t2> <msg>` | `/hq broadcast --only team-a,team-b "Share eval configs"` |
| `inbox` | `/hq inbox` |
| `merge <branch> [--dry-run]` | `/hq merge feature --dry-run` |
| `cherry-pick <branch> <commits>` | `/hq cherry-pick feature abc123,def456` |
| `merge-log` | `/hq merge-log` |
| `share <from-team> <to-team> <finding>` | `/hq share team-a team-b "eval config breakthrough"` |
| `worktrees` | `/hq worktrees` |
| `archive [--name <label>]` | `/hq archive --name mar3-hillclimb` |
| `teardown [--name <label>] [--keep-branches]` | `/hq teardown --name mar3-session` |

### Team Lead Subcommands

| Subcommand | Usage |
|-----------|-------|
| `status` | `/hq status` |
| `report <message>` | `/hq report "LBM at 50k steps, recon_error 0.12"` |
| `report --merge-ready <message>` | `/hq report --merge-ready "Branch ready for merge"` |
| `report --merge-ready --cherry-pick <hashes> <msg>` | `/hq report --merge-ready --cherry-pick abc123,def456 "Two key commits"` |
| `report --finding <text> <message>` | `/hq report --finding "ttRTC improves bottles by 15pp" "Status update"` |
| `inbox` | `/hq inbox` |

If no subcommand or `$ARGUMENTS` is empty, default to `status`.

## Step 2: Execute Subcommand

### `status` — List active teams

```bash
ls -la ~/.claude/hq/worktrees/ 2>/dev/null || echo "No HQ state found"
```

Display the director status and **active teams only** (with merge-ready flags and task summaries).

### `launch` — Launch team lead in new tmux window (Director only)

Parse the worktree path, `--name`, and `--mission` from arguments. Optionally parse `--model` and `--permission-mode`.

```bash
bash .claude/hooks/launch-team.sh \
  --worktree <path> --name <short-name> \
  --mission "<mission-text>" \
  [--model <model>] [--permission-mode <mode>]
```

### `send <team> <message>` — Send directive to one team lead (Director only)

Parse team name, message, and optional `--high` flag.

```bash
bash .claude/hooks/send-directive.sh \
  --to-team <team> [--priority high] \
  "<message>"
```

### `broadcast <message>` — Broadcast to all team leads (Director only)

Check for `--only <list>` and `--high` flag.

```bash
bash .claude/hooks/broadcast-directive.sh \
  [--only <list>] [--priority high] \
  "<message>"
```

### `inbox` — Check inbox for messages

**Director**: Read the HQ team inbox and filter for upward reports:

```bash
python3 -c "
import json, sys, glob
inbox_files = glob.glob(os.path.expanduser('~/.claude/teams/hq/inboxes/*.json'))
for f in inbox_files:
    with open(f) as fh:
        messages = json.load(fh)
    for m in messages:
        if not m.get('read', False):
            text = m['text'][:120] + '...' if len(m['text']) > 120 else m['text']
            print(f'[{m.get(\"timestamp\", \"?\")}] From {m.get(\"from\", \"?\")}:  {text}')
"
```

**Team Lead**: Read your inbox and filter for director directives.

### `report <message>` — Report status to director (Team Lead only)

Auto-detect `--branch` and `--worktree` from the current directory:
```bash
BRANCH=$(git branch --show-current)
WORKTREE=$(pwd)
```

Parse optional flags: `--merge-ready`, `--cherry-pick <commits>`, `--finding <text>`.

```bash
bash .claude/hooks/report-to-hq.sh \
  --from-team <YOUR_TEAM> --branch "$BRANCH" --worktree "$WORKTREE" \
  [--merge-ready] [--merge-type cherry-pick --merge-commits <commits>] \
  [--findings "<finding>"] \
  "<message>"
```

### `merge <branch>` — Merge a branch into mainline (Director only)

1. Read `~/.claude/hq/worktrees/<branch>.json` to get `merge_target`, `merge_type`, and `merge_commits`.
2. Determine the target worktree path from `git worktree list`.
3. If `--dry-run` is specified, run the dry-run first.
4. For real merge, pass `--expected-head` from the dry-run output.
5. On success, notify the source team and broadcast to all teams.
6. On conflict, notify the source team lead with the conflicting files list.

### `cherry-pick <branch> <commits>` — Cherry-pick specific commits (Director only)

Same as `merge` but with cherry-pick mode.

### `merge-log` — View recent merge operations (Director only)

```bash
tail -20 ~/.claude/hq/merge-log.jsonl 2>/dev/null || echo "No merge log found."
```

### `share <from-team> <to-team> <finding>` — Relay a finding between teams (Director only)

The director rewrites the finding for the recipient's context, then sends it as a directive. The director should NOT blindly forward — rewrite for the recipient's context.

### `worktrees` — List all git worktrees (Director only)

```bash
git worktree list
```

### `archive` — Archive session data (Director only)

Archive all conversation logs, team configs, task lists, HQ state, and git patches for the current director session.

Parse optional `--name <label>` from arguments. If no name given, auto-generate from date + current branch.

```bash
# Determine archive name
NAME="${label:-$(date +%Y%m%d)-$(git branch --show-current | sed 's|/|-|g')}"

# Run archive script with auto-discovery
bash .claude/hooks/archive-session.sh --name "$NAME" --all
```

Report the archive location and total size to the user.

### `teardown` — Archive and clean up session (Director only)

Full end-of-session command: archives everything first, then removes all worktrees, branches, team dirs, and project dirs.

Parse optional `--name <label>` and `--keep-branches` from arguments.

```bash
# Step 1: Archive
NAME="${label:-$(date +%Y%m%d)-$(git branch --show-current | sed 's|/|-|g')}"
bash .claude/hooks/archive-session.sh --name "$NAME" --all

# Step 2: Clean up (uses the archive manifest for safety)
ARCHIVE_DIR="$HOME/.claude/archives/$(date +%Y%m%d)-$NAME"
bash .claude/hooks/cleanup-session.sh --archive "$ARCHIVE_DIR" [--keep-branches]
```

**IMPORTANT:** Confirm with the user before running teardown. This removes all worktrees and branches (unless `--keep-branches`).

## Step 3: Information Flow Protocol (Director Standing Behavior)

When processing team lead reports, the director evaluates each finding for cross-team relevance:

- **Always share**: Training failure patterns if another team uses the same architecture
- **Always share**: Data/normalization insights if another team works on a related task
- **Always share**: Mainline merge completions (so teams rebase)
- **Never share**: Raw metric values without context
- **Never share**: One team's failures unless directly actionable for the recipient

## Step 4: Escalation Protocol (Director Standing Behavior)

Track `reported_at` timestamps from `~/.claude/hq/worktrees/*.json`:

1. **1 missed check-in** (>2 ticker intervals since last report): send a nudge
2. **2 missed**: send HIGH priority nudge
3. **3 missed**: alert the user that team is unresponsive
4. Verify tmux window exists: `tmux list-windows -F '#{window_name}' | grep <name>`
