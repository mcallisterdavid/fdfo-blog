---
allowed-tools: Bash(git *), Bash(bash *), Bash(tmux *), Bash(claude *), Bash(mkdir *), Read, Write, Glob, Grep, AskUserQuestion
description: Create a git worktree with dev setup and open Claude in a new tmux session
argument-hint: "<name> [--from <branch>] | list | rm <name>"
---

One-shot worktree creation: creates the git worktree, sets up the dev environment,
writes a context handoff note, and opens a new tmux session with Claude.

Raw arguments: $ARGUMENTS

## Argument Parsing

First, parse the raw arguments to determine the subcommand. Do NOT embed
`$ARGUMENTS` into bash scripts — the substitution mangles shell parsing.
Instead, read the arguments as plain text and extract values yourself.

- If arguments start with `list` → run the **list** subcommand
- If arguments start with `rm ` → run the **rm** subcommand, extract `<name>` after `rm`
- Otherwise → run the **create** subcommand:
  - Extract `<name>` (the first non-flag word)
  - Extract `<branch>` if `--from <branch>` is present
  - Derive: `WORKTREE_PATH = /Users/imcallid/gh_personal/fdfo-blog-<name>`
  - Derive: `BRANCH_NAME = <name>`
  - Derive: `SESSION_NAME = fdfo-<name>`

## Create Subcommand

Run these steps sequentially. Use the derived values directly in each command
(do NOT use shell variable parsing — hardcode the extracted name and branch).

### Step 1: Fetch base branch (if --from was specified)

```bash
git fetch origin <branch>
```

Skip this step if no `--from` was given.

### Step 2: Create the worktree

With `--from`:
```bash
git worktree add -b <BRANCH_NAME> <WORKTREE_PATH> origin/<branch>
```

Without `--from`:
```bash
git worktree add -b <BRANCH_NAME> <WORKTREE_PATH>
```

### Step 3: Setup dev environment

This is a Jekyll blog. Install Ruby dependencies in the worktree:

```bash
cd <WORKTREE_PATH> && bundle install
```

Use a timeout of 300000 (5 minutes). If `Gemfile.lock` exists and gems are already
installed, this step completes quickly.

### Step 4: Write handoff note

Use the Write tool to create a MEMORY.md at the target project's memory directory:
`~/.claude/projects/<escaped-path>/memory/MEMORY.md`

The escaped path replaces `/` with `-` and keeps the leading `-`.
Example: `/Users/imcallid/gh_personal/fdfo-blog-viz` → `~/.claude/projects/-Users-imcallid-gh_personal-fdfo-blog-viz/memory/MEMORY.md`

Create the directory first with `mkdir -p`, then write a MEMORY.md summarizing:
- Where the user came from (current directory and branch)
- The new worktree (path, branch, what --from was used)
- Key context from the current conversation
- Any pending tasks or next steps

If a MEMORY.md already exists there, read it first and merge (don't overwrite).

### Step 5: Pre-trust the directory and launch tmux session

Run a throwaway `claude -p ""` to establish trust, then launch the real session:

```bash
tmux kill-session -t <SESSION_NAME> 2>/dev/null || true
tmux new-session -d -s <SESSION_NAME> -c <WORKTREE_PATH> \
  "bash --login -c 'claude -p \"\" >/dev/null 2>&1; claude; exec bash'"
tmux switch-client -t <SESSION_NAME>
```

This ensures:
- The trust prompt is skipped (claude -p pre-trusts the directory)
- Exiting claude drops to a bash shell (session stays alive)
- The tmux client auto-switches to the new session

## List Subcommand

```bash
echo "=== Git Worktrees ===" && git worktree list && echo "" && echo "=== Tmux Sessions ===" && (tmux list-sessions 2>/dev/null || echo "(no tmux sessions)")
```

## Rm Subcommand

Extract `<name>` from arguments (word after `rm`).
**Confirm with the user before running.**

```bash
tmux kill-session -t fdfo-<name> 2>/dev/null && echo "Killed tmux session" || echo "No tmux session"
git worktree remove /Users/imcallid/gh_personal/fdfo-blog-<name> && echo "Removed worktree" || echo "Failed (try --force?)"
```
