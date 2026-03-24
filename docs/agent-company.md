# Agent Company: director/HQ Management Pattern

How to set up and run a multi-team agent hierarchy where a director/HQ agent coordinates multiple autonomous teams across git worktrees. This enables parallel research across multiple experimental tracks.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     director/HQ Session                          │
│  Worktree: abc (main repo)                                  │
│  Agents: team-lead, secretaries, inbox-reader               │
│  (ONLY coordinators — no workers/analysts)                  │
│                                                             │
│  Responsibilities:                                          │
│  - Strategic direction and priority setting                 │
│  - Cross-team insight propagation                           │
│  - Notebook/leaderboard maintenance                         │
│  - Conflict resolution and resource allocation              │
│  - Regression detection and investigation                   │
└────────────┬──────────────┬──────────────┬──────────────────┘
             │              │              │
    HQ Messages (file-based, async via /hq)
             │              │              │
┌────────────▼───┐ ┌────────▼───────┐ ┌───▼──────────────────┐
│  Team A        │ │  Team B        │ │  Team C              │
│  wt: abc-feat1 │ │  wt: abc-feat2 │ │  wt: abc-feat3       │
│                │ │                │ │                       │
│  Agents:       │ │  Agents:       │ │  Agents:             │
│  - runner(s)   │ │  - code-writer │ │  - researcher        │
│  - training-   │ │  - runner(s)   │ │  - builder           │
│    expert      │ │  - training-   │ │                       │
│  - report-     │ │    expert      │ │                       │
│    writer      │ │                │ │                       │
└────────────────┘ └────────────────┘ └───────────────────────┘
```

## Setup Steps

### 1. Create Worktrees

Use the `/worktree` skill to create isolated worktrees for each team:

```
/worktree <feature-name> --from <base-branch>
```

Each worktree gets:
- Its own git branch
- Its own `.venv` (via `setup_dev.sh`)
- Its own tmux session with Claude
- Its own memory file at `~/.claude/projects/<escaped-path>/memory/MEMORY.md`

### 2. HQ Infrastructure

Cross-team coordination uses the `/hq` command and the director agent (`.claude/agents/director.md`). The messaging infrastructure:

```
~/.claude/
├── commands/               # Slash commands
│   └── hq.md             # Cross-worktree HQ coordination
├── agents/
│   └── director.md             # director/HQ pyramid coordinator
├── hooks/
│   ├── ticker.sh          # Polling driver
│   ├── launch-team.sh     # Spawn team lead in tmux
│   ├── send-directive.sh  # director → team lead messaging
│   ├── report-to-hq.sh   # Team lead → director reports
│   └── ...
└── teams/                 # Auto-created by TeamCreate
    └── {team-name}/
        ├── config.json
        └── inboxes/
```

### 3. Launch Sub-Team Sessions

Use `/hq launch` from the director session:

```
/hq launch ../abc-feature --name feat-team --mission "Run LBM experiments on bottles task"
```

Or use `/cd` to open Claude sessions in each worktree manually.

### 4. Create HQ Team

See [`docs/director-directives.md`](director-directives.md) "director Quick-Start" for the full init sequence.

## director Operating Pattern

### Message Flow

```
director sends directive via /hq send → team-lead inbox → team-lead reads → assigns to agents
Agents complete work → report to team-lead → team-lead sends /hq report → HQ file inbox
Inbox-reader polls file inbox (60s) → SendMessage push summary → director reads instantly
User gives direct input to sub-team → team-lead relays summary to director via /hq report
```

### Auto-Registration

New teams launched via `launch-team.sh` are automatically registered in `~/.claude/hq/monitored-teams.json`. Teams not launched via launch-team.sh self-register on their first `report-to-hq.sh` call. The inbox-reader and secretary read this registry to discover all monitored teams.

**User command propagation:** When the user interacts directly with a sub-team (e.g., via its tmux window), the team lead MUST immediately relay a summary of those instructions to the director via `/hq report --finding "User directed: <summary>"`. The director needs full visibility into all user instructions to coordinate across teams.

### Monitoring Cadence

| Phase | Ticker Interval | Rationale |
|-------|----------------|-----------|
| Startup/active | 45-60s | Fast feedback on launch issues |
| Steady state | 120s | Normal monitoring |
| Compute phase | 180s | Long-running jobs, less to check |
| User away | 180s, 40+ cycles | Autonomous long-term monitoring |

### director Responsibilities

1. **Strategic direction**: Set priorities, approve/reject approaches
2. **Cross-pollination**: Relay findings between teams
3. **Insight capture**: Commit findings to `notebook/` on the HQ branch
4. **Regression detection**: Question suspicious results, demand proper eval seeds
5. **Resource allocation**: Approve/deny cluster launches, suggest GPU types
6. **Self-criticism enforcement**: Push teams to verify results, not celebrate noise

## Common Gotchas

### Split Inbox Problem
`TeamCreate` generates random team names but sub-teams reply to the canonical name. **Fix**: use `init-director.sh` to bridge with symlinks. Always check BOTH inbox paths.

### tmux Session Confusion
`/cd` and `/worktree` use `tmux switch-client` which moves the terminal away from the director session. **Fix**: set `trustAllDirectories: true` in settings.json, or switch back with `Ctrl-b s`.

### Cross-Team Message Latency
HQ messaging is async and file-based. Sub-team reports go to a file inbox that the director doesn't automatically see. **Fix**: the inbox-reader agent (mandatory, 60s ticker) bridges file-based reports to push messaging via `SendMessage`. New teams auto-register in `~/.claude/hq/monitored-teams.json` via `launch-team.sh` and `report-to-hq.sh`.

## Notebook Structure

```
notebook/
├── failure-modes.md       # Machine-readable failure catalog
├── insights.md            # Experiment findings with generality tags
├── leaderboard.md         # Best results per task + model
├── hill-climb/            # HP optimization session data
└── *-scratch.md           # Working notes (gitignored)
```

Each team writes ONLY to their own section. director merges cross-team findings. Entry format:
```
- DATE | FINDING | GENERALITY | SOURCE | TEAM
```
