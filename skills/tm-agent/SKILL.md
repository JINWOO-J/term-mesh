---
name: tm-agent
description: Spawn and control multi-agent Claude/Codex/Gemini/Kiro teams inside term-mesh via the `tm-agent` CLI. Use when the user asks to "spin up a team", "add a reviewer agent", "attach an executor", "broadcast to all agents", "delegate a task to X", "run a team of agents", "spawn N agents in parallel", "detach this agent", or anything that involves coordinating multiple AI agents in split panes. Covers team lifecycle, messaging, task board, autonomous research/solve/consensus/swarm, and the workspace-local `attach`/`detach` flow that adds agents to the caller's current workspace without spawning a new one.
---

# tm-agent — Agent Team Control

`tm-agent` is the team management CLI for term-mesh. It lets any pane (leader or agent) spawn, message, and coordinate other agents that run as split panes or headless daemon subprocesses.

A **team** is a named group of agents sharing a workspace, a socket, a task board, and an inbox. The team's **leader** dispatches work; **members** execute, report, and message back.

## Detect you are inside term-mesh

```bash
[ -n "$TERMMESH_SOCKET" ] && echo "inside term-mesh"
# or
[ -S /tmp/term-mesh.sock ] && echo "daemon running"
```

If neither is true, `tm-agent` commands will fail. Outside term-mesh there is no team coordination surface — use plain `claude`/`codex`/etc. directly instead.

Environment variables injected into every pane inside a team:
- `TERMMESH_SOCKET` — unix socket path for RPC
- `TERMMESH_TEAM` / `TERMMESH_TEAM_NAME` — current team
- `TERMMESH_AGENT_NAME` — this agent's name (empty for leader pane)
- `TERMMESH_PANEL_ID` / `TERMMESH_WORKSPACE_ID` / `TERMMESH_WINDOW_ID` — routing ids

## Two ways to build a team

### 1. `tm-agent create` — spawn a new workspace with a full team

```bash
# 3 claude agents in a brand-new workspace, REPL leader on the left
tm-agent create 3

# Adopt the current pane as leader (no new leader pane created)
tm-agent create 3 --adopt

# Custom roles
tm-agent create --roles "explorer,executor,reviewer"

# Use a preset
tm-agent create --preset standard

# Headless (no GUI panes — daemon-managed subprocesses)
tm-agent create 4 --headless

# Multi-CLI: mix claude/codex/gemini/kiro via --roles syntax
tm-agent create --roles "architect:claude:opus,executor:codex:gpt-5,reviewer:gemini:2.5-pro"

# Resume a previous Claude session for the leader
tm-agent create 3 --resume-session
```

Use this when you want a **fresh workspace dedicated to the team** — the caller keeps their original workspace untouched, and the new workspace opens beside it.

### 2. `tm-agent attach` / `detach` — add agents to the **current** workspace

```bash
# Attach a single agent as a split pane inside the caller's workspace.
# The caller's pane is auto-adopted as the team leader on first attach.
# Team is auto-named `ws-<first8hex>` from the workspace UUID (no typing).
tm-agent attach executor
tm-agent attach reviewer --model opus
tm-agent attach security --name sec1 --cli claude
tm-agent attach worker-a --cli codex --model gpt-5

# Remove an agent (closes the pane, preserves the leader pane)
tm-agent detach executor

# Last detach auto-destroys the team; the leader pane is preserved because it
# was externally owned (the caller's original pane).
```

**When to use `attach` vs `create`:**
- ✅ `attach` — "I'm already working in this workspace and want a reviewer *now*" (no new tab, no leader dupe, minimal disruption)
- ✅ `create` — "I want a dedicated scratch workspace for a multi-agent task" (clean slate, full leader pane)

**Constraints:**
- Must run inside a term-mesh pane (`TERMMESH_PANEL_ID`/`WORKSPACE_ID` required)
- Rejected if the current workspace already hosts a `create`-based team (error `existing_gui_team`)
- Agent names must match `^[a-zA-Z0-9_-]{1,32}$`
- Duplicate agent names within the same workspace team → `agent_name_conflict`
- `tm-agent add <type>` (the older variant) works only for headless teams

## Team lifecycle

```bash
tm-agent list                             # all teams across the app
tm-agent status                           # current team (uses TERMMESH_TEAM env)
tm-agent status --team my-team            # explicit team
tm-agent destroy                          # tear down current team (closes panes, clears state)
tm-agent brief <agent>                    # status + active task + messages + terminal snapshot
```

## Leader → agent messaging

```bash
# Send a one-off instruction (agent decides when to start)
tm-agent send executor 'review Sources/TeamOrchestrator.swift'

# Create a task AND send the instruction in one RPC (preferred for real work)
tm-agent delegate reviewer 'audit auth middleware for CSRF' \
  --title "Auth audit" \
  --accept "no TODO comments" --accept "tests pass" \
  --deps t3 \
  --context "$(cat docs/auth-notes.md)" \
  --auto-fix-budget 3

# Broadcast to every agent
tm-agent broadcast 'pull from main and rebuild'

# Autonomous mode: spawn a headless subprocess for long-running work with no
# leader approval required for edits (be careful with this one)
tm-agent delegate executor '...' --autonomous
```

**Fan-out a task to every idle agent:**
```bash
tm-agent fan-out 'run go vet ./... and report any findings'
```

## Agent → leader (or peer) messaging

From inside an agent pane:
```bash
tm-agent reply 'one-paragraph summary of what I just did'   # quick reply to leader
tm-agent report 'full result body'                          # larger report (written to file too)
tm-agent heartbeat 'still working on X, 40% done'           # progress ping
tm-agent ping --auto --interval 30                          # auto-heartbeat loop until Ctrl-C

tm-agent msg send 'quick note to leader'
tm-agent msg send 'hey reviewer, check line 42' --to reviewer
tm-agent inbox                                              # read messages addressed to me
tm-agent msg list --from-agent executor
tm-agent msg clear
```

## Task board

```bash
# List / query
tm-agent task list
tm-agent task get t3

# Agent lifecycle (inside an agent pane)
tm-agent task start t3
tm-agent heartbeat 'making progress'
tm-agent task review t3 'ready for audit — see report'
tm-agent task done t3 'done, patch landed as 3f2a1b8'
tm-agent task block t3 'waiting on explorer for Sources/X.swift'
tm-agent task fix-attempt t3           # record a retry (auto-blocks when fix budget exhausted)

# Leader lifecycle
tm-agent task create 'Fix hang on IME input' --assign debugger
tm-agent task update t3 pending
tm-agent task reassign t3 reviewer
tm-agent task unblock t3
tm-agent task clear                    # nuke all tasks

# Work-stealing: an idle agent claims the next pending task
tm-agent task claim
```

## Reading agent terminal output

Agents may not proactively report — sometimes the leader needs to look at what's on their screen:

```bash
tm-agent read executor --lines 100     # tail one agent's terminal
tm-agent collect --lines 100           # tail every agent
tm-agent reports                       # all result reports so far
tm-agent result-status                 # which tasks are complete
tm-agent result-collect                # pull full result bodies

# Read the full report file (cli truncates at 1500 chars; files hold the rest)
cat ~/.term-mesh/results/<team>/<task_id>.md
cat ~/.term-mesh/results/<team>/<agent>-reply.md
```

## Waiting for signals

```bash
# Block until any agent reports (default: 120s timeout, mode=report)
tm-agent wait

# Wait for a specific mode: report | msg | blocked | review_ready | idle | any
tm-agent wait --mode any --timeout 300

# Wait for a particular task
tm-agent wait --task t3 --mode review_ready
tm-agent wait --tasks t1,t2,t3 --mode report
```

## Autonomous strategies (multi-agent stigmergy)

These commands let idle agents self-organize via a shared `board.jsonl` coordination log:

```bash
tm-agent research "Rust error handling patterns" --depth deep --budget 8 --web
tm-agent solve "why does the renderer flicker on HiDPI?" --agents 4
tm-agent consensus "monolith vs microservices for this product?" --rounds 4
tm-agent swarm "fix all golangci-lint warnings" --budget 10
tm-agent warmup                                    # pre-warm prompt cache for all agents
```

Options (apply to most strategies):
- `--agents N` — number of participating agents (default: all idle claude agents)
- `--budget N` — max round count
- `--timeout N` — max wait seconds (default: 600)
- `--depth shallow|deep|exhaustive` — research depth
- `--web` — allow web search inside the strategy
- `--focus "hint"` — focus hint injected into every participant

## Interrupting / killing

```bash
tm-agent stop executor           # Ctrl-C a specific agent's terminal
tm-agent stop --all              # Ctrl-C every agent in the team
```

## Context store (shared scratchpad)

```bash
tm-agent context set shared-key "value"
tm-agent context get shared-key
tm-agent context list
```

Useful for passing larger blobs between agents without stuffing them into task descriptions.

## Presets & templates

```bash
tm-agent preset list                       # named agent-set presets (standard, architect, ...)
tm-agent template list                     # task templates
tm-agent template show code-review
```

## Common workflows

### Quick code review by an extra agent

```bash
tm-agent attach reviewer --model opus
tm-agent send reviewer 'review the diff in Sources/TeamOrchestrator.swift and flag regressions'
tm-agent wait --mode report --timeout 600
tm-agent reports
tm-agent detach reviewer
```

### Parallel executors working on a plan

```bash
tm-agent create --roles "executor,executor,executor,reviewer"
tm-agent task create 'Implement R1: JWT auth' --assign executor
tm-agent task create 'Implement R2: refresh' --assign executor
tm-agent task create 'Implement R3: rate limiter' --assign executor
tm-agent task create 'Review all [R1][R2][R3]' --assign reviewer --deps t1,t2,t3
tm-agent broadcast 'claim the next pending task with tm-agent task claim'
tm-agent wait --mode any --timeout 1800
```

### Self-organizing research swarm

```bash
tm-agent create 4
tm-agent research "term-mesh socket focus policy — what's the invariant?" \
  --depth deep --budget 6 --focus "look at CLAUDE.md and Sources/TerminalController+*.swift"
# agents coordinate via board.jsonl, report back when consensus is reached
tm-agent collect --lines 50
```

### "Need a hand with this bug" — attach a debugger agent on the fly

```bash
# While in the middle of a Claude session in the current workspace:
tm-agent attach debugger --model opus
tm-agent send debugger 'reproduce and root-cause the IME hang in GhosttyTerminalView.swift:2750'
tm-agent wait --mode report
tm-agent detach debugger
```

## Invariants and gotchas

- **Socket focus policy** — `tm-agent` commands must **not** steal macOS focus. Issuing `attach` from a caller pane keeps focus on the caller; you won't be yanked into the new agent pane.
- **Main-thread policy** — all telemetry commands (`heartbeat`, `report`, `msg`, status queries) are routed off-main on the Swift side. Never wrap `tm-agent` calls in shell loops that poll faster than ~1s; use `tm-agent wait` instead.
- **Adopted leader** — `attach` and `create --adopt` both treat the caller's pane as leader. The leader pane is never closed by `detach` or last-agent destroy; you keep your session.
- **Workspace-local teams** are named `ws-<first8hex>` (derived from the workspace UUID). Don't create your own team with that naming convention — it will collide.
- **GUI vs headless** — `tm-agent add` only works on `--headless` teams. For GUI (split-pane) teams, use `attach` (current workspace) or `destroy && create` (new workspace).
- **Send delay** — the daemon staggers `team.send`/`team.delegate` deliveries by ~1s per agent to prevent TUI Enter-key drops in Claude Code. When fanning out to many agents, expect a few seconds before all receive the message.
- **Truncation** — agent replies over the socket are capped at 1500 chars. Full reports live in `~/.term-mesh/results/<team>/`. Auto-cleaned after 24h.
- **Leader pane ≠ member pane** — the leader does not show up in `team.status` agents list. It's tracked separately by `leader_panel_id` / `leader_session_id`.
- **Headless agents don't have panes** — `read`/`collect` return empty for them; use `result-collect` or result files instead.

## Raw RPC escape hatch

Every `tm-agent` subcommand is a thin wrapper over a JSON-RPC method on the term-mesh socket. To call one directly (for debugging, scripting, or methods with no CLI wrapper):

```bash
tm-agent raw '{"jsonrpc":"2.0","method":"team.status","params":{"team_name":"ws-abc12345"},"id":1}'
tm-agent raw '{"jsonrpc":"2.0","method":"window.list","params":{},"id":2}'
```

Prefixed method families: `team.*`, `team.agent.*`, `team.task.*`, `team.message.*`, `team.context.*`, `pane.*`, `window.*`, `workspace.*`.

## Batching

For scripts that issue many commands, pack them into a single roundtrip:

```bash
tm-agent batch "send executor:do X; send reviewer:do Y; wait --mode report; collect"
```

## Companion skills

| Skill | When to reach for it |
|-------|---------------------|
| [`term-mesh`](../term-mesh/SKILL.md) | Window/workspace/pane topology without agents (splits, move, focus, flash) |
| [`term-mesh-browser`](../term-mesh-browser/SKILL.md) | Browser automation on WKWebView surfaces (separate from agent team panes) |
| [`term-mesh-debug-windows`](../term-mesh-debug-windows/SKILL.md) | Reading the debug log / diagnosing focus & split issues |

## When NOT to use tm-agent

- Single-agent work that doesn't need coordination — just run `claude` directly.
- Outside term-mesh — there is no socket, nothing to spawn panes into. Use plain CLIs.
- Heavy batch automation where you don't need UI visibility — prefer `--headless` mode or write a dedicated orchestrator.
- When you only need to run **one** command in another pane — `term-mesh new-split ... --command "..."` is simpler than spinning up a whole agent.
