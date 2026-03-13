# Making Agent Teams

Guidelines for composing, planning, and executing multi-agent teams for behavior cloning experiments. Adapted from the RL team playbook.

## When to Use a Team

**Use a team for:**
- Multi-file code changes that benefit from a code-writer + reviewer/tester split
- Experiment launches across multiple tasks or model architectures (parallelize with runners)
- Any plan with 3+ phases or 2+ independent workstreams
- Code changes followed by experiment validation (code-writer gates runners)
- Knowledge mining or documentation updates alongside other work

**A team is overkill for:**
- Single-file edits, typo fixes, small config changes
- A single training launch
- Pure research/exploration questions

## Standing Rules

- **Team structure (name + full agent manifest) must be the first section of every plan that uses teams** — before any phase or task details
- Only `/code-writer` agents modify source code. Multiple may operate in parallel on non-overlapping file partitions (see Parallel Code-Writers below)
- Use a single persistent team across all phases — do not create a new team per phase
- The lead agent never sleeps/polls; delegate polling to a report-writer agent
- The lead MUST NOT run training launches directly — delegate all launches to runner agents
- Launching runners is the START of the experiment phase, not the end — the lead must stay alive to manage monitoring, failures, and result reporting
- No agent blocks with sleep in its main loop; the lead runs a background ticker loop to drive report-writer's polling cycle
- **CRITICAL — Keep turns short to receive messages.** Claude Code's InboxPoller delivers messages only when the session is idle (between turns). Any agent that chains multiple tool calls (sleep loops, polling, sequential commands) blocks ALL message delivery for the entire turn duration. Design agents to do one thing per turn then go idle.
- **Delegation is enforced, not optional.** Team leads with >20 Bash/Edit/Write commands and no Task spawns are in violation. Hard limit: hands-on:delegation ratio must be <2:1. If you've been running commands for 10 minutes without delegating, stop and spawn a sub-agent.
- **No polling loops.** Running the same command (find, ls, ssh, aws s3 ls) more than 3 times waiting for results is BANNED. Use exponential backoff (30s → 1m → 5m → 15m cap), or go idle and let the ticker wake you.
- **Use dedicated tools, not Bash.** Read not cat, Grep not grep, Glob not find, Edit not sed. Bash is only for git/sky/ssh/process management.
- **Mandatory retro before shutdown.** Every team must run a brief retrospective (what worked, what failed, workflow improvements) and commit findings to `notebook/insights.md` or `docs/` before being disbanded. Knowledge-secretary handles the commit.

## Role Catalog

| Role | Type | What it does | What it does NOT do |
|------|------|-------------|---------------------|
| **Lead** | Coordinator | Creates team, assigns tasks, relays messages between agents, reports to user | Write code, run experiments, sleep/poll |
| **Code-writer(s)** | Executor | Modify source code and create commits. Invoke with `/code-writer`. One or more may run in parallel on non-overlapping file partitions. Receives fix requests from lead/training-expert. | Run experiments, launch training jobs |
| **Runners** (1 per experiment) | Executor | Runs `/hill-climb` or launches training via `uv run runners/run_training.py`. Launches jobs and reports cluster/job IDs, then goes idle. Reports results when asked. | Write code, diagnose other runners' tasks |
| **Training-expert** | Advisor | Reviews metrics (recon_error, jerk, train/val gap), diagnoses failures, recommends HP changes. Deep BC/VLA/LBM knowledge. Invoke with `/training-expert`. | Write code, run jobs. Advisory only. |
| **Report-writer** | Monitor | Ticker-driven poller: reacts to `POLL_TRIGGER` messages from lead's background ticker, asks teammates for status, compiles summary, sends to lead. Invoke with `/report-writer`. | Make decisions, write code, sleep |
| **Cheerleader** | Advisor | Pushes back on "impossible" claims with empirical evidence. Tracks prediction accuracy. Keeps team searching. Invoke with `/cheerleader`. | Write code, run jobs, make HP recommendations (that's training-expert's job) |
| **Docs-improver** | Executor | Creates/updates knowledge files, skill prompts, CLAUDE.md with findings from miners, runners, training-expert. Captures knowledge so future sessions don't re-discover known results. | Write algorithm code, run experiments |
| **Miners** | Read-only | Scans conversation history (JSONL files) for insights, failures, design decisions. Reports findings to docs-improver. | Write any files, run experiments |
| **Analyst** | Executor | Loads data files, computes features, reasons about classification rules/thresholds. Multiple analysts can run in parallel per data partition. Code-writers encode rules proposed by analysts. | Write production code (that's code-writer's job) |
| **Director** | Coordinator | Cross-worktree HQ coordinator. Issues directives, controls information flow between team leads, manages merges. Spawns three secretaries for mechanical work. See [`docs/director-directives.md`](director-directives.md). | Sky commands, code changes (except git merge), experiments, direct lead-to-lead messaging |
| **Git Secretary** | Executor | Director's git operations arm. Executes merges, cherry-picks, conflict detection, branch status tracking. Invoke with `/git-secretary`. Takes orders from Director only. | Strategic decisions, launch HQ teams, interact with user directly, resolve conflicts autonomously |
| **Comms Secretary** | Executor | Director's communications arm. Formats team lead reports into digests, delivers directives, tracks acknowledgments, manages escalation timers. Invoke with `/comms-secretary`. | Strategic decisions, filtering reports, autonomous directive delivery |
| **Knowledge Secretary** | Executor | Director's knowledge management arm. Captures cross-team findings into shared docs, maintains findings log, runs `/sync-infra`. Invoke with `/knowledge-secretary`. | Modify source code, change CLAUDE.md without director approval |
| **Notebook-writer** | Executor | Creates/modifies Jupyter notebooks programmatically via Python scripts. Executes and validates. Invoke with `/notebook-writer`. | NotebookEdit for bulk ops, leaving stale outputs |

## Data Flow

The team is a DAG — no cycles. Information flows in one direction between roles:

```
Lead ──assigns──> Code-writer(s) ──commits──> Runners
Lead ──assigns──> Runners
Runners ──metrics──> Report-writer ──summaries/alerts──> Lead
Report-writer ──summaries/alerts──> Training-expert  (via --expert flag)
Training-expert ──data requests──> Runners            (direct, on demand)
Training-expert ──recommendations──> Lead
Training-expert ──diagnosis──> Cheerleader            (claims to challenge)
Cheerleader ──counterpoint──> Lead              (evidence-based pushback)
Training-expert ──analysis──> Report-writer           (for inclusion in reports)
Lead ──fix requests──> Code-writer(s)
Runners ──results──> Docs-improver
Training-expert ──insights──> Docs-improver
```

The apparent loop (runner -> report-writer -> training-expert -> lead -> code-writer(s) -> runner) is iterative, not circular: each cycle processes new runs with new code. Runners don't block waiting for the fix cycle — they continue with other experiments.

**Training-expert data access:** Training-expert can message any teammate to request specific metric values. It discovers teammates via the team config file at startup. Typical targets are runners (raw metrics, W&B run IDs) and report-writer (aggregated summaries). It sends recommendations to lead only — never commands actions directly.

## When to Use Which Roles

| Scenario | Roles needed |
|----------|-------------|
| Single model, single task | Lead + 1 runner + training-expert |
| Multi-architecture tuning sweep | Lead + N runners + training-expert + report-writer |
| Code changes + experiments | Lead + code-writer + runners + training-expert (code-writer must finish first) |
| Parallel cross-module code changes | Lead + N code-writers (non-overlapping partitions) + runners |
| Full pipeline | All roles |

## Key Dynamics

**Code-writer(s) are a bottleneck gate.** Runners cannot launch on new code until ALL code-writers have committed. Parallel writers reduce wall-clock time but the gate still requires every writer to finish before runners proceed. Plan accordingly: schedule code-writer tasks early, before runner tasks.

**Training-expert prevents wasted compute — spawn it from the FIRST launch.** Without it, runners discover failure modes by burning GPU hours. The training-expert catches issues (mode collapse, normalization mismatches, gradient explosion) from metrics before the runner wastes more iterations. **Always include training-expert in any experiment team, even single-task runs.**

**Runners are embarrassingly parallel.** One per experiment (task + architecture combination), independent of each other. Different experiments have different run lengths. Separate runners prevent slow tasks from bottlenecking fast ones. Training launches use `uv run runners/run_training.py`.

**Report-writer is the only polling agent.** It exists so the lead doesn't have to poll. The lead stays reactive; the report-writer pushes summaries when triggered by the lead's background ticker.

## Parallel Code-Writers

When changes span independent modules, multiple code-writers can run in parallel on non-overlapping file partitions.

**Naming:** `code-writer-<partition-label>` (e.g., `code-writer-models`, `code-writer-dataloading`).

**Partition assignment:** The lead specifies each writer's scope as glob patterns in the task description. Suggested partitions based on the abc codebase:

```
code-writer-trainers:       trainers/**
code-writer-models:         models/**
code-writer-dataloading:    dataloading/**
code-writer-transforms:     transforms/**
code-writer-runners:        runners/**
code-writer-deploy:         deploy/**
code-writer-dataprocessing: dataprocessing/**
```

**Rules:**
1. **Partitions must not overlap.** The lead ensures disjoint scopes. If two writers need the same file, merge them into one writer.
2. **Writers must NOT modify files outside their partition.** Escalate to lead instead.
3. **Each writer runs format, lint, and type-check independently.**
4. **Each writer commits independently.** Non-overlapping partitions prevent merge conflicts.
5. **The runner gate requires ALL writers to have committed.** Runners do not launch until every code-writer has finished.
6. **Test gate after all writers commit.** The lead runs the full test suite after ALL code-writers have committed. If tests fail, the lead assigns fix tasks back to the appropriate writer(s).

**Decision table:**

| Situation | Use |
|-----------|-----|
| Tightly-coupled changes across modules | Single code-writer |
| Independent changes in separate modules | Parallel code-writers with partition labels |
| Unclear whether files overlap | Single code-writer (safer default) |

---

## Plan Structure

### Team Section Comes First

Every plan that uses agent teams **MUST** begin with a `## Team` section immediately after any brief context/goal statement — before phases, gates, or task details.

**Why:** If the team structure isn't the first actionable thing the agent reads when executing, it gets skipped. The agent starts executing phases, never creates the team, and runs everything sequentially as a single agent.

**The `## Team` section must contain:**
1. The team name
2. A table of every agent to spawn (name, role/type, responsibility)
3. Which agents are REQUIRED vs optional

### Phase Transition Discipline

Use a single persistent team across all phases. If you must create a new team, re-state the full agent manifest at each phase start:

```markdown
### Phase 2 Agents

Spawn ALL of these before proceeding to any Phase 2 tasks:
- [ ] `code-writer` — REQUIRED, Phase 2.3 fixes
- [ ] `training-expert` — REQUIRED, Phase 2.4 HP consultation
- [ ] `runner-lbm-bottles`
- [ ] `runner-vla-towels`
```

### Hard Gates

Dependencies written as prose ("2.3 must complete before 2.5") get skipped when the agent scans for "what to do next." Use explicit blocking gates:

```markdown
## GATE: Before launching ANY Phase 2.5-2.9 runs:
- [ ] ALL code-writers have committed Phase 2.3 fixes
- [ ] Training-expert has provided per-task HP guidance
- [ ] Data config verified in dataloading/registry.py
- [ ] Normalization stats confirmed matching dataset

DO NOT proceed past this gate until all items pass.
```

### Supporting Roles Are Not Optional

Advisory agents (training-expert) and supporting agents (code-writer, cheerleader) get dropped because they don't "do" the primary task. Mark them explicitly:

```markdown
- `training-expert` — REQUIRED. Advisory only but prevents wasted compute
  from known failure modes. Do not skip.
```

If a role exists in the plan, it must be spawned. There is no implicit "nice to have."

### Redundancy at Point of Use

Information stated once in a long plan gets forgotten. Fix:
- Restate dependencies at the phase start, not just in a global section
- Reference the data flow DAG at each transition
- Repeat the agent manifest at every phase boundary

### Execution Constraints

Include this block in every multi-phase plan:

```markdown
## Execution Rules
- Execute all phases end-to-end. Do not stop at phase boundaries
  to await user input unless explicitly instructed.
- At each phase transition, re-read the plan's agent manifest.
  Cross-check spawned agents against it — don't spawn from memory.
- Never re-plan from scratch at phase transitions — consult the
  original plan document.
```

### Polling Rules

- **No agent blocks with sleep in its main loop.** The lead runs a background bash ticker loop to drive report-writer's polling cycle — this runs in a background process, not in the agent's turn. Runners do not self-poll; they respond to status requests from report-writer (check `sky logs --status`, check W&B at far.wandb.io).
- The lead agent NEVER sleeps. It reacts to teammate messages and report-writer summaries.
- Report-writer is purely reactive — it responds to `POLL_TRIGGER` messages from the lead's ticker.
- All other agents stay reactive — no sleep-based polling.
- NEVER use `TaskOutput(block=true)` on background processes — it blocks the entire turn just like `sleep`. Use `block=false` or tail the log file instead.
- Use `run_in_background: true` for non-blocking status checks.
