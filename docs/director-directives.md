# Director Directives

Standing rules for the director agent and all sub-teams. The director reads this at session start. Sub-teams receive these via `/hq` directives.

---

## 0. Core Director Directive (Inviolable)

**THE DIRECTOR NEVER GIVES UP AND NEVER STOPS.**

- The director MUST keep running, monitoring, and driving toward ALL session objectives until achieved or the user explicitly says stop.
- NEVER shut down monitoring because "things are quiet." If objectives are unmet, restart teams, spawn new agents, try new approaches.
- NEVER prematurely conclude a session. If sub-teams go idle, WAKE THEM UP.
- If the user is away, operate AUTONOMOUSLY — launch clusters, assign tasks, pivot approaches.
- Monitoring agents (report-writer, ticker) run INDEFINITELY until the user says stop.

---

## 1. Director Quick-Start

When acting as the director (HQ coordinator across worktrees):

1. **Initialize HQ identity first** — run `bash .claude/hooks/init-director.sh --pre` to clean stale state, then `TeamCreate(team_name="hq")`, then `bash .claude/hooks/init-director.sh --post <actual-name>` where `<actual-name>` is whatever TeamCreate returned.
2. **Spawn the secretary agent immediately** — handles all mechanical coordination (manifest building, batch spawning, result collection). Mandatory, not optional.
3. **Use `/hq launch`** to start team leads — never manually `TeamCreate` + `TaskCreate` + `Task`
4. **Do NOT explore, audit, or code** — delegate everything to team leads and the secretary
5. **After launch**: monitor via `/hq inbox` and `/hq status`
6. The director's only tools are `/hq *` subcommands, merge operations, and messages to the secretary

**Anti-pattern: director spawning teams inline.** The director must never use `TeamCreate` + `TaskCreate` + `Task` to stand up a team in its own session. Always use `/hq launch`, which creates the team lead in its own tmux window. Inline setup blocks the director session and bypasses the team lead lifecycle.

### HQ Session Init

`TeamCreate(team_name="hq")` may assign a random name if `~/.claude/teams/hq/` already exists. `init-director.sh` bridges this gap with a symlink.

**Full sequence (run at the start of every director session):**

```bash
# Phase 1: clean stale state
bash .claude/hooks/init-director.sh --pre
```

Then call `TeamCreate(team_name="hq")`. Note the actual team name it returns.

```bash
# Phase 2: bridge inbox if TeamCreate assigned a different name
bash .claude/hooks/init-director.sh --post <actual-team-name>
```

---

## 2. Operational Directives

### Communication
1. **HQ polling**: Check inbox (`/hq inbox`) every 5 minutes minimum.
2. **Reply to director within 2 cycles** (even brief "acknowledged").
3. **Agent health**: Check and respawn dead agents within 10 min.
4. **Push code within 5 min of changes.** Commit and push early and often.
5. **Status reports to director every 15 min** during active work.

### Model Selection
6. **Always use Opus for sub-agents** — when spawning teammates via the `Task` tool, always set `model: "opus"`. This applies to all agent types (code-writers, runners, researchers, etc.). Do not use Sonnet or Haiku for teammates.

### No Sleeping, No Blocking, No Spinning
6. **NEVER use `sleep` in any agent** — sleep blocks the entire thread and wastes context. No exceptions.
7. **NEVER use `TaskOutput(block=true)` on background processes** — it blocks the turn just like sleep. Use `block=false` or tail the log file.
8. **Use the ticker pattern** — background ticker drives polling via `POLL_TRIGGER`. Report-writer reacts. All other agents stay reactive.
9. **NEVER poll in a loop** — running the same command (find, ls, ssh, aws s3 ls) more than 3 times waiting for results is BANNED. Instead:
   - Use exponential backoff: 30s → 1m → 5m → 15m cap. After 3 checks, double the interval each time.
   - For local files, use `inotifywait -t <timeout> -e create <dir>` instead of sleep-poll.
   - For remote jobs (Sky, SSH), check once per ticker cycle (every 5-15 min), not continuously.
   - If results aren't ready after 6 checks, report status to lead and go idle — let the ticker wake you.

### Delegation Enforcement
10. **Leads NEVER execute work directly** — all code, evals, launches, analysis go to teammates. If you're writing code or running commands, you're doing it wrong — spawn a teammate.
11. **Hard delegation limit** — if a team lead has run >20 Bash/Edit/Write commands without spawning a sub-agent, STOP and delegate. Team leads with a hands-on:delegation ratio >2:1 are in violation. The director will flag and warn.
12. **Team lead pledge** — Every new team lead MUST print this as their first output:
    ```
    From now on I will ONLY:
      1. Send messages to teammates with tasks
      2. Read teammate reports
      3. Report to HQ
      4. Update task lists
    Zero hands-on execution.
    ```

### Dedicated Tool Usage
13. **Use dedicated tools, not Bash equivalents.** This is enforced, not optional:
    - `Read` not `cat`, `head`, `tail` — for reading file contents
    - `Grep` not `grep`, `rg` — for searching file contents
    - `Glob` not `find`, `ls` — for finding files by pattern
    - `Edit` not `sed`, `awk` — for modifying files
    - `Write` not `echo >`, `cat <<EOF >` — for creating files
    - `TaskOutput` not `tail /tmp/.../*.output` — for checking agent output
    - Bash is ONLY for: git commands, sky commands, ssh, process management, and system operations that have no dedicated tool.

### Code & Repos
10. **Never push directly to master/main** — always feature branches + PRs.
7. **All training on Sky**, never locally (except smoke tests).
8. **Never download checkpoints locally** — keep on S3, run on Sky.

### Agent Teams
9. **Default to agent teams for any non-trivial task.** Never run research directly as lead.
10. **Always use `TeamCreate`** — never use standalone subagents for research.
11. **Don't ask user for confirmation on director directives** — route questions to director, not user.
12. **Worktree naming**: always `abc-<feature-name>` as siblings of the main repo (e.g., `../abc-my-feature`). NEVER `FAR-abc-<name>`.
13. **HQ team contains ONLY director + secretaries + notebook-auditor. NEVER spawn workers/analysts/researchers in HQ.** All research, analysis, code, eval, and diagnostic tasks MUST be pushed to sub-teams via directives (`send-directive.sh`). If a task needs doing, send a directive to the relevant sub-team — do NOT spawn a teammate in HQ. This is absolute, not a preference. **Spawn multiple secretaries** to load-balance mechanical coordination work (notebook fixes, file organization, status checks, git pushes). Name them `secretary-1`, `secretary-2`, etc. Each can handle independent tasks in parallel. **Spawn a notebook-auditor** on the ticker to periodically audit all notebooks in the HQ notebooks directory — enforces: all cells executed, videos use correct HTML pattern (type="video/mp4", base64-embedded, H.264 baseline), YYMMDD_HHMM naming, no loose files. Reports violations to the director for enforcement.

### Infrastructure
14. **AWS_PROFILE**: Prefix CLI commands with `env -u AWS_PROFILE` to clear inherited profile.
15. **Always use `uv run python`** instead of `python3` or `python`.

---

## 3. Quality Directives

### Eval Standards
- **20+ seeds minimum** for any quantitative claim. 10-seed evals have ±10pp noise.
- **40+ seeds for confirmation**, 100+ for publication-grade results.
- **Bound iteration budget**: 2 iterations max per hypothesis before pivoting.
- **Check W&B** for prior runs before starting any experiment.
- **Match reference scale** (batch_size × train_steps) before tuning HPs.

### Self-Criticism
- Push teams to verify results, not celebrate noise. Regression detection is the director's key role.
- Question suspicious results — demand evidence before claiming breakthroughs.

---

## 4. Team Management

### Standing Rules for All Teams
- **ACK all directives** — team leads must acknowledge every director directive with a short `/hq report`.
- **Propagate user commands to HQ** — when the user gives instructions directly to a sub-team (e.g., via the tmux window), the team lead MUST relay a summary of those instructions to the director via `/hq report --finding "User directed: <summary>"`. The director needs full context of all user instructions across all teams to coordinate effectively. Do this IMMEDIATELY after receiving user input.
- **Notebooks must be pre-executed** — all Jupyter notebooks surfaced to HQ must be run before committing so the director can open and view results immediately. Use `jupyter nbconvert --to notebook --execute --inplace <notebook>.ipynb` to execute. Never commit unexecuted notebooks.
- **Notebooks tracked on director branch** — all notebooks go in `experiments/260303_eval_missions/notebooks/` on the director tree (arthur/mar3/director), NOT in random directories. Teams should write notebooks to this path directly or coordinate with the secretary to copy them there.
- **Notebook naming convention** — all new notebooks use the format `YYMMDD_HHMM_descriptive_name.ipynb` where HHMM is UTC (e.g., `260303_2045_pen_insertion_gemini_diagnosis.ipynb`). Existing notebooks keep their current names.
- **Notebook timestamps** — inside every new notebook, include both UTC and PST times in the header (e.g., "Created: 2026-03-03 20:45 UTC / 12:45 PST"). Filenames use UTC only.
- **Video encoding for browser compatibility** — all exported videos must use H.264 baseline profile with yuv420p pixel format at 30fps for Firefox/Jupyter playback: `ffmpeg -i input.mp4 -c:v libx264 -profile:v baseline -pix_fmt yuv420p -r 30 -movflags +faststart output.mp4`.
- **Videos belong inside notebooks** — do NOT produce standalone .mp4 files. Embed all videos directly in Jupyter notebooks (e.g., using `IPython.display.Video` or base64 inline). The notebook is the deliverable, not loose files.
- **No standalone .md reports** — all reports must be Jupyter notebooks with markdown cells (renders nicely in Jupyter). Never produce loose .md files — use `.ipynb` with markdown cells instead.
- **No loose images** — embed all PNGs/images directly in notebooks. No standalone image files in the notebooks directory.
- **Gemini model** — always use `gemini-3.1-pro-preview` for visual analysis. Never use flash models for spatial reasoning tasks.
- **Lead must not run sky commands** — delegate to runner agents.
- **Start ticker immediately after report-writer** — `bash .claude/hooks/ticker.sh`.
- **Sanity-check before bulk launches** — 1 test run before N.
- **Delegation from first message** — leads and director coordinate, never execute.
- **Never delete the team config** — only the director disbands teams.
- **Kill all background tasks before shutdown** — tickers, sky jobs, background shells.
- **Cross-worktree coordination via HQ** — all cross-team info flows through the director, no peer-to-peer.
- **Escalate bug fixes immediately** — when a team discovers a cross-team bug, `/hq report --finding` right away.

### Merge Rules
- **NEVER merge to master** — merges go to a working integration branch only.
- **Always get explicit user approval** before merging or cherry-picking.
- **Serialize merges** — one at a time, broadcast update after each.

---

## 5. HQ Coordination

- **File-based async messaging** via `~/.claude/teams/{team}/inboxes/` and `/hq` command.
- **Cross-team messages** route through the director (see `.claude/agents/director.md`).
- **GOTCHA: Split inboxes** — TeamCreate generates random names. Use `init-director.sh` to bridge.
- **tmux switch-client** in /cd and /worktree moves terminal away — causes pane spawning failures.

### Inbox-Reader Agent (MANDATORY)

The director MUST spawn an **inbox-reader** agent immediately after the secretary. This agent bridges the gap between file-based sub-team reports and Claude Code's push messaging:

1. Runs on a **60-second ticker** (`bash .claude/hooks/ticker.sh -t hq -r inbox-reader -i 60`)
2. On each `POLL_TRIGGER`, reads `~/.claude/teams/hq/inboxes/team-lead.json`
3. Filters for unread messages, groups by source team
4. Sends a **SendMessage** summary to the director (push notification)
5. **Escalates URGENT/HIGH messages immediately** with distinct prefix
6. Marks messages as read after delivery

Without this agent, the director has NO way to receive sub-team reports — they go to a file that nobody reads.

### Auto-Registration for New Teams

New sub-teams are automatically registered in `~/.claude/hq/monitored-teams.json` via two mechanisms:

1. **Primary (launch-team.sh)**: When `launch-team.sh` launches a new team lead, the background poller registers the team and notifies the director + all secretaries.
2. **Fallback (report-to-hq.sh)**: When a team reports to HQ for the first time and isn't in the registry, it self-registers.

The inbox-reader and secretary should read `monitored-teams.json` to discover which teams to monitor. This eliminates the coverage gap where teams created after the secretary was spawned go unmonitored.

---

## 6. Session Teardown

When a director session is complete (all objectives met or user says stop), follow this shutdown sequence:

### Standard Shutdown Flow

1. **All team leads report final status** — send `/hq broadcast "Prepare final report and merge readiness status"` and wait for all teams to respond.
2. **Director merges approved branches** — process all merge-ready reports via `/hq merge`. Serialize merges (one at a time).
3. **Archive the session** — run `/hq archive --name <label>` to preserve all conversation logs, team configs, task lists, HQ state, and git patches for dirty worktrees.
4. **Teardown** — run `/hq teardown --name <label>` to archive (if not already done) and clean up all worktrees, branches, team dirs, and project dirs. Use `--keep-branches` to preserve branches.
5. **Archive location** — data is saved to `~/.claude/archives/<YYYYMMDD>-<name>/` for future reference.

### What Gets Archived

| Data | Location in Archive |
|------|-------------------|
| Conversation logs (per-worktree) | `conversations/<worktree>/` |
| Team configs + inboxes | `teams/<team>/` |
| Task lists | `tasks/<team>/` |
| HQ state (inbox, directives, merge log) | `hq/` |
| Federation message log | `hq/federation-message-log.jsonl` |
| Git diffs for dirty worktrees | `patches/<worktree>-tracked.patch` |
| Untracked file lists | `patches/<worktree>-untracked.txt` |
| Branch → SHA mapping | `branches.txt` |
| Session metadata | `manifest.json` |

### Single-Worktree Archive

To archive and remove a single worktree (e.g., when a team finishes early):

```bash
bin/wt remove <branch> -D --archive
```

This archives the worktree's conversation data + team config before removing it.

### Manual Archive & Cleanup

```bash
# Archive only (no cleanup)
bash .claude/hooks/archive-session.sh --name <label> --all

# Clean up using an existing archive's manifest
bash .claude/hooks/cleanup-session.sh --archive ~/.claude/archives/<YYYYMMDD>-<label>/

# Clean up specific items without an archive (DANGEROUS — no safety net)
bash .claude/hooks/cleanup-session.sh --worktrees /path/to/wt1,/path/to/wt2 --teams team1,team2

# Dry-run cleanup to see what would be removed
bash .claude/hooks/cleanup-session.sh --archive ~/.claude/archives/<YYYYMMDD>-<label>/ --dry-run
```

---

## Quick Reference

| Parameter | Value |
|-----------|-------|
| Min eval seeds | 20 |
| Confirmation seeds | 40+ |
| Publication seeds | 100+ |
| Inbox check interval | 5 min |
| Status report interval | 15 min |
| Code push deadline | 5 min |
| Agent health check | 10 min |
| director reply deadline | 2 cycles |
| Max iterations/hypothesis | 2 |
