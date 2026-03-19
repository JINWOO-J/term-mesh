# tm-bench — Agent Team Communication Benchmark

Run automated benchmarks on the term-mesh agent team communication system.
Measures RPC infrastructure latency and end-to-end agent response times.
Supports **pane vs headless** infrastructure and **terminal vs LLM leader** modes.
Results are saved as JSON and compared with previous runs to track improvements.

## Arguments

User provided: $ARGUMENTS

## Routing

Parse `$ARGUMENTS` to determine the subcommand:

| Input | Command |
|-------|---------|
| `agent` | **Interactive selector** (use `AskUserQuestion`, see below) |
| (empty) | **Interactive selector** (same as `agent`) |
| `agent --pane` | `python3 scripts/bench-agent.py --mode pane` |
| `agent --headless` | `python3 scripts/bench-agent.py --mode headless` |
| `agent --llm` | `python3 scripts/bench-agent.py --leader llm` |
| `agent --terminal` | `python3 scripts/bench-agent.py --leader terminal --mode pane` |
| `agent --rpc` | `python3 scripts/bench-agent.py --rpc-only --mode pane --leader terminal` |
| `agent --e2e` | `python3 scripts/bench-agent.py --e2e-only --mode pane --leader terminal` |
| `agent --note "..."` | append `--note "..."` to the command |
| `history` | `python3 scripts/bench-agent.py --history` |
| `compare A B` | `python3 scripts/bench-agent.py --compare A B` |

Map the first word of `$ARGUMENTS`:

- **`agent` (no flags)** or **empty** → Interactive selector (see Interactive Flow below)
- **`agent` (with flags)** → Map `--pane` to `--mode pane`, `--headless` to `--mode headless`, `--llm` to `--leader llm`, `--terminal` to `--leader terminal`. Pass remaining flags through.
- **`history`** → Show history: `python3 scripts/bench-agent.py --history`
- **`compare`** → Compare runs: `python3 scripts/bench-agent.py --compare` followed by the remaining args.

## Interactive Flow (for bare `agent` or empty arguments)

When `$ARGUMENTS` is empty or just `agent` with no flags:

1. **Detect current state** — Run `tm-agent status` to check for an active team (name, agent count).

2. **Ask with `AskUserQuestion`** — Present a single-select question based on detected state:

   **Question:** "Which benchmark to run?"
   **Header:** "Benchmark"

   Build options dynamically:

   | Option label | Description | When to show | Maps to |
   |---|---|---|---|
   | **Existing team E2E (Recommended)** | `{team_name} ({N} agents), no new team — fastest` | Team detected | `--e2e-only --mode pane --leader terminal` |
   | **Existing team E2E** | `No active team detected — will fail without one` | No team | `--e2e-only --mode pane --leader terminal` |
   | **Full pane benchmark** | `RPC (temp team) + E2E (existing team)` | Always | `--mode pane --leader terminal` |
   | **RPC only** | `Infrastructure latency only (creates temp team)` | Always | `--rpc-only --mode pane --leader terminal` |
   | **LLM leader E2E** | `Creates new team with --claude-leader` | Always | `--leader llm` |

   When team is detected: show 4 options (Existing team E2E recommended, Full pane, RPC only, LLM leader).
   When no team: show 3 options (Full pane recommended, RPC only, LLM leader). Skip "Existing team E2E".

3. **Run the mapped command** — Take the user's selection, map to the flags above, and execute:
   ```
   python3 scripts/bench-agent.py {mapped flags}
   ```

4. **Show output** to the user.

## Subcommand Reference

| Command | Description |
|---------|-------------|
| `agent` | Interactive menu: select leader type + infra mode + layers |
| `agent --pane` | Pane infrastructure only |
| `agent --headless` | Headless infrastructure only |
| `agent --llm` | LLM leader E2E (creates team with --claude-leader) |
| `agent --terminal` | Terminal leader E2E (script-driven, uses existing team) |
| `agent --rpc` | RPC latency benchmarks only |
| `agent --e2e` | E2E agent communication only |
| `agent --note "msg"` | Attach a change description to the benchmark run |
| `history` | Show last 10 benchmark results in a table |
| `compare A B` | Side-by-side comparison of two runs by timestamp prefix |

## Leader Types

| | Terminal Leader | LLM Leader |
|---|---|---|
| **Who** | Script / user types `tm-agent delegate` | Claude agent orchestrates autonomously |
| **Routing** | Fixed assignment | Context-aware, by agent specialty |
| **Verification** | Status field check | Semantic response interpretation |
| **Error handling** | Timeout → FAIL | Re-delegate, reassign, retry |
| **Overhead** | ~0ms | LLM call latency (~2-10s) |

## Execution

1. Parse `$ARGUMENTS` and run the appropriate `python3 scripts/bench-agent.py` command via Bash
2. If no flags → show interactive menu for configuration
3. Show the output to the user
4. Results are automatically saved to `~/.term-mesh/benchmarks/YYYY-MM-DDTHH-MM-SS.json`
5. If a previous run exists, a comparison delta is printed automatically
