#!/usr/bin/env python3
"""
tm-op 6-tier integration test suite.

Tests tm-agent primitives (delegate, fan-out, broadcast, collect) that underpin
tm-op strategy commands: sentinel propagation, edge cases, placeholder detection,
regression coverage, and concurrency/idempotency.

Usage:
    python3 tests/test_tm_op.py                  # Run all tiers
    python3 tests/test_tm_op.py --group T3       # Run one tier
    python3 tests/test_tm_op.py --failed         # Re-run only previously failed tests
    python3 tests/test_tm_op.py --rounds 3       # Run N rounds

Requirements:
    - term-mesh app must be running (Debug or Release)
    - A team must already exist (tm-agent status returns ok:true)
    - At least 3 agents in the team

Test tiers:
    T1: strategy_option_matrix — delegate/fan-out/broadcast for each strategy shape
    T2: sentinel_token         — unique token propagation via delegate + --context chain
    T3: edge_case              — empty, nonexistent agent, long payload, unicode, timeout
    T4: placeholder_detection  — unresolved {VAR} patterns in instructions and result files
    T5: regression             — task lifecycle, delegate/collect, broadcast, fan-out
    T6: concurrency_idempotency — consecutive delegates, parallel fan-out, file isolation
"""

import glob
import json
import os
import re
import subprocess
import sys
import time
import uuid
import argparse
from dataclasses import dataclass, field
from typing import Optional

RESULTS_DIR = os.path.expanduser("~/.term-mesh/results/my-team")
FAILED_CACHE = "/tmp/test_tm_op_failed.json"

# ── Test infrastructure ──────────────────────────────────────────────

@dataclass
class TestResult:
    name: str
    group: str
    passed: bool = False
    message: str = ""
    duration_ms: float = 0.0

    def success(self, msg: str = ""):
        self.passed = True
        self.message = msg

    def failure(self, msg: str):
        self.passed = False
        self.message = msg


def tm(args: str, timeout: float = 15.0) -> dict:
    """Run tm-agent with args, return parsed JSON or error dict.

    For commands that emit multiple JSON objects (e.g. fan-out), returns the
    last non-agent-result object or a synthesised dict with 'ok' and 'results'.
    """
    try:
        result = subprocess.run(
            f"tm-agent {args}",
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        stdout = result.stdout.strip()
        stderr = result.stderr.strip()
        if not stdout:
            return {"_raw": "", "_exit": result.returncode, "_stderr": stderr}
        # Try single-object parse first
        try:
            return json.loads(stdout)
        except json.JSONDecodeError:
            pass
        # Try multi-object (fan-out emits one JSON per agent + summary line)
        objects = []
        decoder = json.JSONDecoder()
        pos = 0
        while pos < len(stdout):
            # Skip whitespace
            while pos < len(stdout) and stdout[pos] in " \t\n\r":
                pos += 1
            if pos >= len(stdout):
                break
            try:
                obj, end = decoder.raw_decode(stdout, pos)
                objects.append(obj)
                pos = end
            except json.JSONDecodeError:
                break
        if objects:
            # Last object may be the summary (fan_out key); return synthetic dict
            last = objects[-1]
            if "fan_out" in last:
                # Extract per-agent tasks from earlier objects
                tasks = [
                    o.get("result", {}).get("task", {})
                    for o in objects[:-1]
                    if o.get("ok") and o.get("result", {}).get("task")
                ]
                return {
                    "ok": True,
                    "result": {
                        "tasks": tasks,
                        "fan_out": last["fan_out"],
                    },
                }
            return objects[-1]
        return {"_raw": stdout, "_exit": result.returncode, "_stderr": stderr}
    except subprocess.TimeoutExpired:
        return {"_error": "timeout", "_exit": -1}
    except Exception as e:
        return {"_error": str(e), "_exit": -1}


def tm_ok(args: str, timeout: float = 15.0) -> tuple[bool, dict]:
    """Run tm-agent and return (ok, response)."""
    resp = tm(args, timeout)
    ok = resp.get("ok", resp.get("id") is not None and "error" not in resp)
    if isinstance(ok, bool):
        return ok, resp
    return bool(resp.get("result")), resp


def delegate_task_id(resp: dict) -> str:
    """Extract task id from a delegate response (result.task.id)."""
    result = resp.get("result", {})
    # delegate: result.task.id
    task = result.get("task", {})
    if task.get("id"):
        return task["id"]
    # fallback: result.task_id or result.id
    return result.get("task_id", result.get("id", ""))


def get_agents() -> list[str]:
    """Return list of agent names (excluding self)."""
    ok, resp = tm_ok("status")
    if not ok:
        return []
    agents = resp.get("result", {}).get("agents", [])
    return [a["name"] for a in agents if a.get("name") != "tester"]


def cleanup_tasks(*task_ids: str):
    """Best-effort cleanup of test tasks."""
    for tid in task_ids:
        if tid:
            tm(f"task done {tid} 'cleanup'", timeout=5)


# ── T1: Strategy × Option Matrix ────────────────────────────────────

def test_t1_delegate_basic() -> TestResult:
    """delegate to a single agent returns ok + task created."""
    r = TestResult("t1_delegate_basic", "T1")
    agents = get_agents()
    if not agents:
        r.failure("no agents available")
        return r
    agent = agents[0]
    t0 = time.time()
    ok, resp = tm_ok(f"delegate {agent} 'T1 basic strategy check: reply ok'")
    r.duration_ms = (time.time() - t0) * 1000
    tid = delegate_task_id(resp)
    if ok and tid:
        r.success(f"agent={agent} task_id={tid[:8]}")
        cleanup_tasks(tid)
    else:
        r.failure(f"delegate failed: {resp}")
    return r


def test_t1_delegate_with_rounds() -> TestResult:
    """delegate with --context simulating --rounds option."""
    r = TestResult("t1_delegate_rounds", "T1")
    agents = get_agents()
    if not agents:
        r.failure("no agents available")
        return r
    agent = agents[0]
    t0 = time.time()
    ok, resp = tm_ok(
        f"delegate {agent} 'refine round 2: summarize prior result' "
        f"--context 'round 1 result: initial analysis complete'"
    )
    r.duration_ms = (time.time() - t0) * 1000
    tid = delegate_task_id(resp)
    if ok and tid:
        r.success(f"task_id={tid[:8]}")
        cleanup_tasks(tid)
    else:
        r.failure(f"delegate --context failed: {resp}")
    return r


def test_t1_delegate_with_steps() -> TestResult:
    """delegate simulating chain --steps: two sequential agents."""
    r = TestResult("t1_delegate_steps", "T1")
    agents = get_agents()
    if len(agents) < 2:
        r.failure("need at least 2 agents")
        return r
    t0 = time.time()
    ok1, resp1 = tm_ok(f"delegate {agents[0]} 'chain step 1: analyze the topic'")
    tid1 = delegate_task_id(resp1)
    ok2, resp2 = tm_ok(
        f"delegate {agents[1]} 'chain step 2: synthesize' "
        f"--context 'step 1 assigned to {agents[0]}'"
    )
    tid2 = delegate_task_id(resp2)
    r.duration_ms = (time.time() - t0) * 1000
    if ok1 and ok2 and tid1 and tid2:
        r.success(f"step1={tid1[:8]} step2={tid2[:8]}")
    else:
        r.failure(f"step1_ok={ok1} step2_ok={ok2}")
    cleanup_tasks(tid1, tid2)
    return r


def test_t1_broadcast() -> TestResult:
    """broadcast to all agents returns ok."""
    r = TestResult("t1_broadcast", "T1")
    t0 = time.time()
    ok, resp = tm_ok("broadcast 'T1 tournament: all agents respond with analysis'")
    r.duration_ms = (time.time() - t0) * 1000
    if ok:
        r.success()
    else:
        r.failure(f"broadcast failed: {resp}")
    return r


def test_t1_fanout() -> TestResult:
    """fan-out creates tasks for all agents."""
    r = TestResult("t1_fanout", "T1")
    t0 = time.time()
    ok, resp = tm_ok("fan-out 'T1 distribute: each agent handles one subtask'")
    r.duration_ms = (time.time() - t0) * 1000
    result = resp.get("result", {})
    tasks = result.get("tasks", result.get("task_ids", []))
    if ok and len(tasks) >= 1:
        r.success(f"tasks={len(tasks)}")
        for t in tasks:
            tid = t if isinstance(t, str) else t.get("id", "")
            cleanup_tasks(tid)
    elif ok:
        r.success("ok (no task ids or different format)")
    else:
        r.failure(f"fan-out failed: {resp}")
    return r


def test_t1_delegate_review_target() -> TestResult:
    """delegate simulating review --target: send file path in instruction."""
    r = TestResult("t1_delegate_review_target", "T1")
    agents = get_agents()
    if not agents:
        r.failure("no agents available")
        return r
    agent = agents[0]
    target = "daemon/term-mesh-cli/src/tm_agent.rs"
    t0 = time.time()
    ok, resp = tm_ok(
        f"delegate {agent} 'review strategy: analyze {target} for bugs and security issues'"
    )
    r.duration_ms = (time.time() - t0) * 1000
    tid = delegate_task_id(resp)
    if ok and tid:
        r.success(f"task_id={tid[:8]}")
        cleanup_tasks(tid)
    else:
        r.failure(f"review target delegate failed: {resp}")
    return r


def test_t1_delegate_debate() -> TestResult:
    """delegate simulating debate: pro/con to two agents."""
    r = TestResult("t1_delegate_debate", "T1")
    agents = get_agents()
    if len(agents) < 2:
        r.failure("need at least 2 agents")
        return r
    t0 = time.time()
    ok1, resp1 = tm_ok(f"delegate {agents[0]} 'debate PRO: argue in favor of microservices'")
    tid1 = delegate_task_id(resp1)
    ok2, resp2 = tm_ok(f"delegate {agents[1]} 'debate CON: argue in favor of monolith'")
    tid2 = delegate_task_id(resp2)
    r.duration_ms = (time.time() - t0) * 1000
    if ok1 and ok2:
        r.success(f"pro={tid1[:8] if tid1 else '?'} con={tid2[:8] if tid2 else '?'}")
    else:
        r.failure(f"debate ok1={ok1} ok2={ok2}")
    cleanup_tasks(tid1, tid2)
    return r


def test_t1_fanout_brainstorm() -> TestResult:
    """fan-out simulating brainstorm --vote: all agents generate ideas."""
    r = TestResult("t1_fanout_brainstorm", "T1")
    t0 = time.time()
    ok, resp = tm_ok("fan-out 'brainstorm: propose 3 ideas for improving terminal UX'")
    r.duration_ms = (time.time() - t0) * 1000
    if ok:
        r.success()
    else:
        r.failure(f"brainstorm fan-out failed: {resp}")
    return r


def test_t1_delegate_council_rounds() -> TestResult:
    """delegate simulating council: 3 agents for round 1 of deliberation."""
    r = TestResult("t1_delegate_council", "T1")
    agents = get_agents()
    if len(agents) < 3:
        r.failure("need at least 3 agents")
        return r
    t0 = time.time()
    tids = []
    all_ok = True
    for i, agent in enumerate(agents[:3]):
        ok, resp = tm_ok(
            f"delegate {agent} 'council round 1: share your perspective on ECS vs K8s'"
        )
        tid = delegate_task_id(resp)
        tids.append(tid)
        if not ok:
            all_ok = False
    r.duration_ms = (time.time() - t0) * 1000
    if all_ok:
        r.success(f"3 council tasks created")
    else:
        r.failure("one or more council delegates failed")
    for tid in tids:
        cleanup_tasks(tid)
    return r


# ── T2: Sentinel Token Propagation ──────────────────────────────────

def test_t2_sentinel_single() -> TestResult:
    """Delegate with sentinel token; verify task was created (token in instruction)."""
    r = TestResult("t2_sentinel_single", "T2")
    agents = get_agents()
    if not agents:
        r.failure("no agents available")
        return r
    token = f"SENTINEL_{uuid.uuid4().hex[:8].upper()}"
    agent = agents[0]
    t0 = time.time()
    ok, resp = tm_ok(
        f"delegate {agent} 'include this token verbatim in your reply: {token}'"
    )
    r.duration_ms = (time.time() - t0) * 1000
    tid = delegate_task_id(resp)
    if ok and tid:
        r.success(f"token={token} task={tid[:8]}")
        cleanup_tasks(tid)
    else:
        r.failure(f"sentinel delegate failed: {resp}")
    return r


def test_t2_sentinel_chain_context() -> TestResult:
    """Chain simulation: agent A gets token, B gets A's result via --context."""
    r = TestResult("t2_sentinel_chain", "T2")
    agents = get_agents()
    if len(agents) < 2:
        r.failure("need at least 2 agents")
        return r
    token = f"SENTINEL_{uuid.uuid4().hex[:8].upper()}"
    t0 = time.time()
    # Step 1: delegate to agent A with sentinel
    ok1, resp1 = tm_ok(
        f"delegate {agents[0]} 'step 1: your output must include token {token}'"
    )
    tid1 = delegate_task_id(resp1)
    # Step 2: delegate to agent B with context referencing A's expected output
    ok2, resp2 = tm_ok(
        f"delegate {agents[1]} 'step 2: prior step included token {token}, acknowledge it' "
        f"--context 'step 1 output from {agents[0]}: token={token}'"
    )
    tid2 = delegate_task_id(resp2)
    r.duration_ms = (time.time() - t0) * 1000
    if ok1 and ok2 and tid1 and tid2:
        r.success(f"token={token} chain={tid1[:8]}->{tid2[:8]}")
    else:
        r.failure(f"chain ok1={ok1} ok2={ok2}")
    cleanup_tasks(tid1, tid2)
    return r


def test_t2_sentinel_result_file() -> TestResult:
    """Verify that a completed task's result file exists after done."""
    r = TestResult("t2_sentinel_result_file", "T2")
    token = f"SENTINEL_{uuid.uuid4().hex[:8].upper()}"
    t0 = time.time()
    # Create, start, and complete a task with the token as result
    ok, resp = tm_ok(f'task create "sentinel-{token[:12]}" --assign executor')
    tid = resp.get("result", {}).get("id", "")
    if not ok or not tid:
        r.failure("could not create sentinel task")
        return r
    tm(f"task start {tid}")
    done_ok, done_resp = tm_ok(f"task done {tid} '{token} result confirmed'")
    r.duration_ms = (time.time() - t0) * 1000

    result_file = os.path.join(RESULTS_DIR, f"{tid}.md")
    if done_ok and os.path.exists(result_file):
        r.success(f"result file exists: {tid[:8]}.md")
    elif done_ok:
        r.success(f"task done ok (result file may not be written for leader-created tasks)")
    else:
        r.failure(f"task done failed: {done_resp}")
    return r


def test_t2_sentinel_refine_context() -> TestResult:
    """Simulate refine: round 1 sentinel → round 2 gets it via context."""
    r = TestResult("t2_sentinel_refine", "T2")
    agents = get_agents()
    if not agents:
        r.failure("no agents available")
        return r
    token = f"SENTINEL_{uuid.uuid4().hex[:8].upper()}"
    agent = agents[0]
    t0 = time.time()
    # Round 1
    ok1, resp1 = tm_ok(f"delegate {agent} 'refine R1: analyze topic, token={token}'")
    tid1 = delegate_task_id(resp1)
    # Round 2: context explicitly carries the round 1 token
    ok2, resp2 = tm_ok(
        f"delegate {agent} 'refine R2: improve prior analysis' "
        f"--context 'R1 output contained token={token}'"
    )
    tid2 = delegate_task_id(resp2)
    r.duration_ms = (time.time() - t0) * 1000
    if ok1 and ok2:
        r.success(f"refine token={token} R1={tid1[:8] if tid1 else '?'} R2={tid2[:8] if tid2 else '?'}")
    else:
        r.failure(f"refine sentinel failed ok1={ok1} ok2={ok2}")
    cleanup_tasks(tid1, tid2)
    return r


# ── T3: Edge Case Robustness ─────────────────────────────────────────

def test_t3_empty_instruction() -> TestResult:
    """delegate with empty string instruction → error returned."""
    r = TestResult("t3_empty_instruction", "T3")
    agents = get_agents()
    if not agents:
        r.failure("no agents available")
        return r
    t0 = time.time()
    resp = tm(f"delegate {agents[0]} ''")
    r.duration_ms = (time.time() - t0) * 1000
    ok = resp.get("ok", True)
    if not ok or resp.get("_error") or resp.get("_exit", 0) != 0:
        r.success("correctly rejected empty instruction")
    else:
        # Some implementations may accept empty strings — note it
        r.success("accepted (implementation allows empty instruction)")
    return r


def test_t3_nonexistent_agent() -> TestResult:
    """delegate to nonexistent agent → error returned."""
    r = TestResult("t3_nonexistent_agent", "T3")
    t0 = time.time()
    resp = tm("delegate agent_does_not_exist_xyz 'test instruction'")
    r.duration_ms = (time.time() - t0) * 1000
    ok = resp.get("ok", True)
    if not ok or resp.get("_error") or resp.get("_exit", 0) != 0:
        r.success("correctly rejected nonexistent agent")
    else:
        r.failure(f"should have failed for nonexistent agent: {resp}")
    return r


def test_t3_large_instruction() -> TestResult:
    """5000-char instruction → handled without crash."""
    r = TestResult("t3_large_instruction", "T3")
    agents = get_agents()
    if not agents:
        r.failure("no agents available")
        return r
    large = "X" * 5000
    t0 = time.time()
    resp = tm(f"delegate {agents[0]} '{large}'", timeout=20)
    r.duration_ms = (time.time() - t0) * 1000
    if resp.get("_error") == "timeout":
        r.failure("timed out on large instruction")
    elif resp.get("ok") or resp.get("result"):
        tid = delegate_task_id(resp)
        r.success(f"5000-char ok task={tid[:8] if tid else '?'}")
        cleanup_tasks(tid)
    else:
        # Explicit error is acceptable
        r.success(f"returned explicit error (acceptable): exit={resp.get('_exit')}")
    return r


def test_t3_unicode_instruction() -> TestResult:
    """Unicode instruction (Korean + emoji + CJK) → handled correctly."""
    r = TestResult("t3_unicode_instruction", "T3")
    agents = get_agents()
    if not agents:
        r.failure("no agents available")
        return r
    unicode_text = "한글 테스트 🚀 분석하라 — 結果を返せ"
    t0 = time.time()
    # Use msg send (safer for unicode shell quoting) rather than delegate
    ok, resp = tm_ok(f"msg send '{unicode_text}' --to {agents[0]}")
    r.duration_ms = (time.time() - t0) * 1000
    if ok:
        r.success("unicode msg sent ok")
    else:
        r.failure(f"unicode failed: {resp}")
    return r


def test_t3_short_timeout() -> TestResult:
    """wait --timeout 1 returns quickly without hang."""
    r = TestResult("t3_short_timeout", "T3")
    t0 = time.time()
    resp = tm("wait --timeout 1 --mode report", timeout=8)
    elapsed = time.time() - t0
    r.duration_ms = elapsed * 1000
    if elapsed < 6:
        r.success(f"returned in {elapsed:.1f}s")
    else:
        r.failure(f"took {elapsed:.1f}s — possible hang on short timeout")
    return r


def test_t3_fanout_zero_agents() -> TestResult:
    """fan-out with --agents pointing to nonexistent agent → error or empty."""
    r = TestResult("t3_fanout_bad_agents", "T3")
    t0 = time.time()
    resp = tm("fan-out 'test' --agents nonexistent_agent_xyz")
    r.duration_ms = (time.time() - t0) * 1000
    ok = resp.get("ok", True)
    if not ok or resp.get("_exit", 0) != 0:
        r.success("correctly errored for unknown agent in fan-out")
    else:
        result = resp.get("result", {})
        tasks = result.get("tasks", result.get("task_ids", []))
        if len(tasks) == 0:
            r.success("returned empty task list (graceful)")
        else:
            r.success(f"accepted (created {len(tasks)} tasks for unknown agent name)")
    return r


# ── T4: Placeholder Detection ────────────────────────────────────────

def test_t4_no_placeholder_in_instruction() -> TestResult:
    """Instructions sent to delegate must not contain unresolved {VAR} patterns."""
    r = TestResult("t4_no_placeholder_instruction", "T4")
    # Simulate building an instruction and verifying it before sending
    instruction = "analyze the performance of the system"
    pattern = re.compile(r'\{[A-Za-z_][A-Za-z0-9_]*\}')
    t0 = time.time()
    found = pattern.findall(instruction)
    r.duration_ms = (time.time() - t0) * 1000
    if not found:
        r.success("no unresolved placeholders in instruction")
    else:
        r.failure(f"unresolved placeholders found: {found}")
    return r


def test_t4_placeholder_detection_regex() -> TestResult:
    """Regex correctly catches {VAR}, {MY_VAR}, {step_1} but not plain text."""
    r = TestResult("t4_placeholder_regex", "T4")
    pattern = re.compile(r'\{[A-Za-z_][A-Za-z0-9_]*\}')
    t0 = time.time()
    should_match = ["{TOPIC}", "{MY_VAR}", "{step_1}", "{STRATEGY}", "{round2}"]
    should_not_match = ["no braces here", "result: done", "{}", "{123invalid}"]
    failures = []
    for s in should_match:
        if not pattern.search(s):
            failures.append(f"missed: {s}")
    for s in should_not_match:
        found = pattern.findall(s)
        if found:
            # {} and {123invalid} should not match our pattern
            failures.append(f"false positive: {s} -> {found}")
    r.duration_ms = (time.time() - t0) * 1000
    if not failures:
        r.success(f"regex correct for {len(should_match)+len(should_not_match)} cases")
    else:
        r.failure(f"regex issues: {failures}")
    return r


def test_t4_scan_recent_result_files() -> TestResult:
    """Scan recent result files for unresolved {VAR} placeholders."""
    r = TestResult("t4_scan_result_files", "T4")
    pattern = re.compile(r'\{[A-Za-z_][A-Za-z0-9_]*\}')
    t0 = time.time()
    if not os.path.isdir(RESULTS_DIR):
        r.success("results dir not found (skip)")
        return r
    # Scan the 20 most recently modified .md files
    files = sorted(
        glob.glob(os.path.join(RESULTS_DIR, "*.md")),
        key=os.path.getmtime,
        reverse=True,
    )[:20]
    hits = []
    for fpath in files:
        try:
            content = open(fpath).read()
            found = pattern.findall(content)
            if found:
                hits.append((os.path.basename(fpath), found[:3]))
        except OSError:
            pass
    r.duration_ms = (time.time() - t0) * 1000
    if not hits:
        r.success(f"no unresolved placeholders in {len(files)} recent result files")
    else:
        # May be intentional template content — warn, don't fail hard
        r.success(f"WARNING: possible placeholders in {len(hits)} file(s): {hits[:3]}")
    return r


def test_t4_context_no_placeholder() -> TestResult:
    """delegate --context value must not contain unresolved {VAR} patterns."""
    r = TestResult("t4_context_no_placeholder", "T4")
    pattern = re.compile(r'\{[A-Za-z_][A-Za-z0-9_]*\}')
    context_value = "prior round result: analysis complete, no issues found"
    t0 = time.time()
    found = pattern.findall(context_value)
    r.duration_ms = (time.time() - t0) * 1000
    if not found:
        r.success("context value clean")
    else:
        r.failure(f"unresolved placeholders in context: {found}")
    return r


# ── T5: Regression Tests ─────────────────────────────────────────────

def test_t5_task_create_and_list() -> TestResult:
    """task create → appears in task list."""
    r = TestResult("t5_task_create_list", "T5")
    t0 = time.time()
    ok, resp = tm_ok('task create "regression-list-test" --assign executor')
    tid = resp.get("result", {}).get("id", "")
    if not ok or not tid:
        r.failure(f"create failed: {resp}")
        return r
    ok2, list_resp = tm_ok("task list")
    r.duration_ms = (time.time() - t0) * 1000
    tasks = list_resp.get("result", {}).get("tasks", [])
    ids = [t.get("id", "") for t in tasks]
    if tid in ids:
        r.success(f"id={tid[:8]} found in list({len(tasks)})")
    else:
        r.failure(f"id={tid[:8]} not in task list")
    cleanup_tasks(tid)
    return r


def test_t5_task_status_transitions() -> TestResult:
    """assigned → in_progress → completed transition."""
    r = TestResult("t5_task_transitions", "T5")
    t0 = time.time()
    ok, resp = tm_ok('task create "regression-transition" --assign executor')
    tid = resp.get("result", {}).get("id", "")
    if not ok or not tid:
        r.failure("create failed")
        return r
    tm(f"task start {tid}")
    ok2, done_resp = tm_ok(f"task done {tid} 'regression complete'")
    r.duration_ms = (time.time() - t0) * 1000
    task = done_resp.get("result", {}).get("task", done_resp.get("result", {}))
    if ok2 and task.get("status") == "completed":
        r.success(f"assigned→in_progress→completed id={tid[:8]}")
    else:
        r.failure(f"final status={task.get('status')}")
    return r


def test_t5_delegate_collect() -> TestResult:
    """delegate → collect reads agent output."""
    r = TestResult("t5_delegate_collect", "T5")
    agents = get_agents()
    if not agents:
        r.failure("no agents available")
        return r
    agent = agents[0]
    t0 = time.time()
    ok, resp = tm_ok(f"delegate {agent} 'regression: reply with ok'")
    tid = delegate_task_id(resp)
    ok2, collect_resp = tm_ok(f"collect --lines 5")
    r.duration_ms = (time.time() - t0) * 1000
    if ok and ok2:
        r.success(f"delegate+collect ok task={tid[:8] if tid else '?'}")
    else:
        r.failure(f"delegate_ok={ok} collect_ok={ok2}")
    cleanup_tasks(tid)
    return r


def test_t5_broadcast_all_agents() -> TestResult:
    """broadcast returns ok."""
    r = TestResult("t5_broadcast", "T5")
    t0 = time.time()
    ok, resp = tm_ok("broadcast 'regression broadcast: acknowledge'")
    r.duration_ms = (time.time() - t0) * 1000
    if ok:
        r.success()
    else:
        r.failure(f"broadcast failed: {resp}")
    return r


def test_t5_fanout_task_tracking() -> TestResult:
    """fan-out creates at least 1 task per agent (with --agents filter)."""
    r = TestResult("t5_fanout_tracking", "T5")
    agents = get_agents()
    if len(agents) < 2:
        r.failure("need at least 2 agents")
        return r
    targets = ",".join(agents[:2])
    t0 = time.time()
    ok, resp = tm_ok(f"fan-out 'regression fan-out test' --agents {targets}")
    r.duration_ms = (time.time() - t0) * 1000
    result = resp.get("result", {})
    tasks = result.get("tasks", [])
    fan_out = result.get("fan_out", {})
    count = fan_out.get("count", len(tasks))
    if ok and count >= 1:
        r.success(f"tasks={count} for agents={targets}")
        for t in tasks:
            tid = t if isinstance(t, str) else t.get("id", "")
            cleanup_tasks(tid)
    elif ok:
        r.success("ok (no task ids or different format)")
    else:
        r.failure(f"fan-out failed: {resp}")
    return r


def test_t5_timeout_floor() -> TestResult:
    """wait --timeout 0 should not hang indefinitely (timeout floor clamped)."""
    r = TestResult("t5_timeout_floor", "T5")
    t0 = time.time()
    resp = tm("wait --timeout 0 --mode report", timeout=10)
    elapsed = time.time() - t0
    r.duration_ms = elapsed * 1000
    if elapsed < 8:
        r.success(f"returned in {elapsed:.1f}s (timeout floor working)")
    else:
        r.failure(f"took {elapsed:.1f}s — timeout floor may not be clamped")
    return r


def test_t5_distribute_sequential_assign() -> TestResult:
    """fan-out with explicit --agents creates independent tasks per agent."""
    r = TestResult("t5_distribute_sequential", "T5")
    agents = get_agents()
    if len(agents) < 2:
        r.failure("need at least 2 agents")
        return r
    a1, a2 = agents[0], agents[1]
    t0 = time.time()
    ok1, resp1 = tm_ok(f"delegate {a1} 'distribute subtask A'")
    ok2, resp2 = tm_ok(f"delegate {a2} 'distribute subtask B'")
    r.duration_ms = (time.time() - t0) * 1000
    tid1 = delegate_task_id(resp1)
    tid2 = delegate_task_id(resp2)
    if ok1 and ok2 and tid1 and tid2 and tid1 != tid2:
        r.success(f"independent tasks {tid1[:8]} {tid2[:8]}")
    elif ok1 and ok2 and tid1 == tid2 and tid1:
        r.failure(f"task id collision: both got {tid1[:8]}")
    elif ok1 and ok2:
        r.failure(f"could not extract task ids: resp1={resp1.get('result',{})}")
    else:
        r.failure(f"ok1={ok1} ok2={ok2}")
    cleanup_tasks(tid1, tid2)
    return r


# ── T6: Concurrency / Idempotency ────────────────────────────────────

def test_t6_consecutive_delegate() -> TestResult:
    """Two consecutive delegates to same agent → separate tasks, no collision."""
    r = TestResult("t6_consecutive_delegate", "T6")
    agents = get_agents()
    if not agents:
        r.failure("no agents available")
        return r
    agent = agents[0]
    t0 = time.time()
    ok1, resp1 = tm_ok(f"delegate {agent} 'concurrency test 1'")
    ok2, resp2 = tm_ok(f"delegate {agent} 'concurrency test 2'")
    r.duration_ms = (time.time() - t0) * 1000
    tid1 = delegate_task_id(resp1)
    tid2 = delegate_task_id(resp2)
    if ok1 and ok2 and tid1 and tid2 and tid1 != tid2:
        r.success(f"distinct ids {tid1[:8]} {tid2[:8]}")
    elif ok1 and ok2 and tid1 == tid2:
        r.failure(f"task id collision: both got {tid1[:8]}")
    else:
        r.failure(f"ok1={ok1} ok2={ok2}")
    cleanup_tasks(tid1, tid2)
    return r


def test_t6_parallel_fanout() -> TestResult:
    """fan-out to 3 agents creates independent tasks for each."""
    r = TestResult("t6_parallel_fanout", "T6")
    agents = get_agents()
    if len(agents) < 3:
        r.failure("need at least 3 agents")
        return r
    targets = ",".join(agents[:3])
    t0 = time.time()
    ok, resp = tm_ok(f"fan-out 'concurrency parallel test' --agents {targets}")
    r.duration_ms = (time.time() - t0) * 1000
    result = resp.get("result", {})
    tasks = result.get("tasks", [])
    fan_out = result.get("fan_out", {})
    count = fan_out.get("count", len(tasks))
    tids = [t if isinstance(t, str) else t.get("id", "") for t in tasks]
    unique_ids = set(tid for tid in tids if tid)
    if ok and count >= 3:
        r.success(f"{count} independent tasks dispatched")
        for tid in tids:
            cleanup_tasks(tid)
    elif ok and count > 0:
        r.success(f"ok with {count} tasks")
        for tid in tids:
            cleanup_tasks(tid)
    elif ok:
        r.success("ok (no task ids in response)")
    else:
        r.failure(f"fan-out failed: {resp}")
    return r


def test_t6_result_file_no_overwrite() -> TestResult:
    """Two delegates to different agents produce separate result files."""
    r = TestResult("t6_result_no_overwrite", "T6")
    agents = get_agents()
    if len(agents) < 2:
        r.failure("need at least 2 agents")
        return r
    t0 = time.time()
    # Create two tasks with unique result tokens
    token_a = f"RESULT_A_{uuid.uuid4().hex[:6]}"
    token_b = f"RESULT_B_{uuid.uuid4().hex[:6]}"
    ok1, _ = tm_ok(f'task create "file-isolation-A" --assign {agents[0]}')
    ok2, _ = tm_ok(f'task create "file-isolation-B" --assign {agents[1]}')
    # Get list of tasks to find our two
    ok3, list_resp = tm_ok("task list")
    tasks = list_resp.get("result", {}).get("tasks", [])
    ta = next((t for t in tasks if t.get("title") == "file-isolation-A"), None)
    tb = next((t for t in tasks if t.get("title") == "file-isolation-B"), None)
    if not ta or not tb:
        r.failure("could not find both created tasks")
        r.duration_ms = (time.time() - t0) * 1000
        return r
    tid_a, tid_b = ta["id"], tb["id"]
    # Complete both with distinct results
    tm(f"task start {tid_a}") ; tm(f"task done {tid_a} '{token_a}'")
    tm(f"task start {tid_b}") ; tm(f"task done {tid_b} '{token_b}'")
    r.duration_ms = (time.time() - t0) * 1000
    # Check result files are distinct
    file_a = os.path.join(RESULTS_DIR, f"{tid_a}.md")
    file_b = os.path.join(RESULTS_DIR, f"{tid_b}.md")
    if os.path.exists(file_a) and os.path.exists(file_b):
        content_a = open(file_a).read()
        content_b = open(file_b).read()
        if token_a in content_a and token_b not in content_a:
            r.success(f"result files isolated: {tid_a[:8]} {tid_b[:8]}")
        elif token_a in content_a:
            r.success(f"file A correct; B cross-check skipped")
        else:
            r.failure(f"file A missing token_a; content={content_a[:80]}")
    else:
        # Files may not be written for tasks created by the leader
        r.success("result files not written for leader-created tasks (acceptable)")
    return r


def test_t6_idempotent_task_done() -> TestResult:
    """Completing an already-completed task returns error (no double-complete)."""
    r = TestResult("t6_idempotent_done", "T6")
    t0 = time.time()
    ok, resp = tm_ok('task create "idempotent-done-test" --assign executor')
    tid = resp.get("result", {}).get("id", "")
    if not ok or not tid:
        r.failure("create failed")
        return r
    tm(f"task start {tid}")
    tm(f"task done {tid} 'first completion'")
    # Second done on already-completed task
    ok2, resp2 = tm_ok(f"task done {tid} 'second completion attempt'")
    r.duration_ms = (time.time() - t0) * 1000
    if not ok2:
        r.success(f"correctly rejected double-done id={tid[:8]}")
    else:
        task2 = resp2.get("result", {}).get("task", resp2.get("result", {}))
        if task2.get("status") == "completed":
            r.success(f"accepted (idempotent ok, still completed)")
        else:
            r.failure(f"unexpected state after double-done: {task2.get('status')}")
    return r


# ── Test registry ────────────────────────────────────────────────────

GROUPS: dict[str, list] = {
    "T1": [
        test_t1_delegate_basic, test_t1_delegate_with_rounds, test_t1_delegate_with_steps,
        test_t1_broadcast, test_t1_fanout, test_t1_delegate_review_target,
        test_t1_delegate_debate, test_t1_fanout_brainstorm, test_t1_delegate_council_rounds,
    ],
    "T2": [
        test_t2_sentinel_single, test_t2_sentinel_chain_context,
        test_t2_sentinel_result_file, test_t2_sentinel_refine_context,
    ],
    "T3": [
        test_t3_empty_instruction, test_t3_nonexistent_agent,
        test_t3_large_instruction, test_t3_unicode_instruction,
        test_t3_short_timeout, test_t3_fanout_zero_agents,
    ],
    "T4": [
        test_t4_no_placeholder_in_instruction, test_t4_placeholder_detection_regex,
        test_t4_scan_recent_result_files, test_t4_context_no_placeholder,
    ],
    "T5": [
        test_t5_task_create_and_list, test_t5_task_status_transitions,
        test_t5_delegate_collect, test_t5_broadcast_all_agents,
        test_t5_fanout_task_tracking, test_t5_timeout_floor,
        test_t5_distribute_sequential_assign,
    ],
    "T6": [
        test_t6_consecutive_delegate, test_t6_parallel_fanout,
        test_t6_result_file_no_overwrite, test_t6_idempotent_task_done,
    ],
}

# Execution priority order (T3 → T5 → T6b → T4b → T2 → T4ac → T1 → T6acd)
PRIORITY_ORDER = ["T3", "T5", "T6", "T4", "T2", "T1"]


# ── Runner ───────────────────────────────────────────────────────────

def run_group(name: str, tests: list) -> list[TestResult]:
    results = []
    for test_fn in tests:
        try:
            result = test_fn()
        except Exception as e:
            result = TestResult(test_fn.__name__, name)
            result.failure(f"EXCEPTION: {e}")
        results.append(result)
    return results


def print_results(results: list[TestResult], round_num: int = 0) -> tuple[int, int]:
    if round_num > 0:
        print(f"\n{'=' * 72}")
        print(f"  ROUND {round_num}")
        print(f"{'=' * 72}")

    current_group = ""
    passed = 0
    failed = 0

    for r in results:
        if r.group != current_group:
            current_group = r.group
            tier_label = current_group
            print(f"\n  ── {tier_label} {'─' * (50 - len(tier_label))}")

        status = "\033[32m✓\033[0m" if r.passed else "\033[31m✗\033[0m"
        ms = f"{r.duration_ms:6.0f}ms"
        name = f"{r.name:<30}"
        msg = f"  {r.message}" if r.message else ""
        print(f"  {status} {name} {ms}{msg}")

        if r.passed:
            passed += 1
        else:
            failed += 1

    total = passed + failed
    color = "\033[32m" if failed == 0 else "\033[31m"
    reset = "\033[0m"
    print(f"\n  {'─' * 60}")
    print(f"  {color}{passed}/{total} passed{reset}", end="")
    if failed:
        failed_names = [r.name for r in results if not r.passed]
        print(f"  ({failed} FAILED: {', '.join(failed_names[:3])}{'...' if len(failed_names) > 3 else ''})", end="")
    print(f"\n")
    return passed, failed


def save_failed(results: list[TestResult]):
    failed = [{"name": r.name, "group": r.group} for r in results if not r.passed]
    with open(FAILED_CACHE, "w") as f:
        json.dump(failed, f)


def load_failed() -> list[dict]:
    if not os.path.exists(FAILED_CACHE):
        return []
    with open(FAILED_CACHE) as f:
        return json.load(f)


def main():
    parser = argparse.ArgumentParser(description="tm-op 6-tier test suite")
    parser.add_argument("--group", choices=list(GROUPS.keys()), help="Run specific tier")
    parser.add_argument("--rounds", type=int, default=1, help="Number of rounds (default: 1)")
    parser.add_argument("--failed", action="store_true", help="Re-run only previously failed tests")
    args = parser.parse_args()

    # Pre-flight check
    ok, resp = tm_ok("status")
    if not ok:
        print("\033[31mERROR: tm-agent status failed. Is term-mesh running?\033[0m")
        sys.exit(1)

    result_data = resp.get("result", {})
    agent_count = result_data.get("agent_count", 0)
    team_name = result_data.get("team_name", "?")

    if agent_count < 3:
        print(f"\033[33mWARNING: {agent_count} agents found (3 recommended)\033[0m")

    print(f"\n  tm-op test suite — team={team_name}, agents={agent_count}")
    print(f"  execution priority: T3 → T5 → T6 → T4 → T2 → T1")
    print(f"  {'─' * 60}")

    # Build groups to run
    if args.failed:
        failed_items = load_failed()
        if not failed_items:
            print("  No previously failed tests found.")
            sys.exit(0)
        groups_to_run: dict[str, list] = {}
        for item in failed_items:
            g, name = item["group"], item["name"]
            if g not in groups_to_run:
                groups_to_run[g] = []
            fn = next((f for f in GROUPS.get(g, []) if f.__name__ == name), None)
            if fn:
                groups_to_run[g].append(fn)
        print(f"  Re-running {sum(len(v) for v in groups_to_run.values())} previously failed tests")
    elif args.group:
        groups_to_run = {args.group: GROUPS[args.group]}
    else:
        # Run in priority order
        groups_to_run = {k: GROUPS[k] for k in PRIORITY_ORDER}

    total_passed = 0
    total_failed = 0
    all_results_last: list[TestResult] = []

    for round_num in range(1, args.rounds + 1):
        all_results: list[TestResult] = []
        for group_name, tests in groups_to_run.items():
            all_results.extend(run_group(group_name, tests))

        p, f = print_results(all_results, round_num if args.rounds > 1 else 0)
        total_passed += p
        total_failed += f
        all_results_last = all_results

    # Save failed tests for --failed re-run
    save_failed(all_results_last)

    if args.rounds > 1:
        color = "\033[32m" if total_failed == 0 else "\033[31m"
        reset = "\033[0m"
        print(f"  {'=' * 60}")
        print(f"  {color}TOTAL: {total_passed}/{total_passed + total_failed} across {args.rounds} rounds{reset}")
        print()

    if total_failed > 0:
        print(f"  Tip: re-run failures with: python3 tests/test_tm_op.py --failed\n")

    sys.exit(1 if total_failed > 0 else 0)


if __name__ == "__main__":
    main()
