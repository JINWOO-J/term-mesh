#!/usr/bin/env python3
"""
Automated tests for team RPC socket interface.

Tests team lifecycle operations: create, list, status, send, broadcast, destroy.

Usage:
    python3 test_team_rpc.py

Requirements:
    - term-mesh must be running with the socket controller enabled
      (TERMMESH_SOCKET_MODE=allowAll)
"""

import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from termmesh import termmesh, termmeshError


class TestResult:
    def __init__(self, name: str):
        self.name = name
        self.passed = False
        self.message = ""

    def success(self, msg: str = ""):
        self.passed = True
        self.message = msg

    def failure(self, msg: str):
        self.passed = False
        self.message = msg


TEAM_NAME = "test-rpc-team"


def _rpc_call(sock_path: str, method: str, params: dict, rid: int = 1,
              timeout: float = 10.0) -> dict:
    """Send a JSON-RPC call over Unix socket and return parsed response."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(sock_path)
        payload = json.dumps({"id": rid, "method": method, "params": params}) + "\n"
        s.sendall(payload.encode())
        data = b""
        while b"\n" not in data:
            chunk = s.recv(8192)
            if not chunk:
                break
            data += chunk
        return json.loads(data.decode())
    finally:
        s.close()


def _detect_socket() -> str:
    """Auto-detect a connectable term-mesh socket."""
    env_sock = os.environ.get("TERMMESH_SOCKET")
    if env_sock and os.path.exists(env_sock):
        return env_sock

    import glob
    candidates = sorted(glob.glob("/tmp/term-mesh*.sock"), key=os.path.getmtime, reverse=True)
    for c in candidates:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(1)
            s.connect(c)
            s.close()
            return c
        except (OSError, socket.error):
            continue
    raise RuntimeError("No connectable term-mesh socket found")


def _cleanup_team(sock_path: str):
    """Best-effort team cleanup."""
    try:
        _rpc_call(sock_path, "team.destroy", {"team_name": TEAM_NAME}, rid=999)
    except Exception:
        pass


def test_ping(sock_path: str) -> TestResult:
    """Test basic socket connectivity with system.ping."""
    result = TestResult("system.ping")
    try:
        resp = _rpc_call(sock_path, "system.ping", {}, rid=0)
        if resp.get("ok"):
            result.success("Received pong")
        else:
            result.failure(f"Ping returned ok=false: {resp}")
    except Exception as e:
        result.failure(f"Connection failed: {e}")
    return result


def test_team_create(sock_path: str) -> TestResult:
    """Test team creation via RPC."""
    result = TestResult("team.create")
    try:
        resp = _rpc_call(sock_path, "team.create", {
            "team_name": TEAM_NAME,
            "agents": [{"name": "w1", "model": "sonnet", "agent_type": "general"}],
            "working_directory": os.getcwd(),
            "leader_session_id": "test-leader-1",
        }, rid=1)
        if resp.get("ok"):
            result.success(f"Team '{TEAM_NAME}' created")
        else:
            result.failure(f"Create failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_team_list(sock_path: str) -> TestResult:
    """Test that created team appears in team.list."""
    result = TestResult("team.list")
    try:
        resp = _rpc_call(sock_path, "team.list", {}, rid=2)
        if not resp.get("ok"):
            result.failure(f"List failed: {resp.get('error', resp)}")
            return result
        teams = resp.get("result", {})
        # team.list returns team names in some form — check our team exists
        result_str = json.dumps(teams)
        if TEAM_NAME in result_str:
            result.success(f"Team '{TEAM_NAME}' found in list")
        else:
            result.failure(f"Team '{TEAM_NAME}' not in list: {result_str[:200]}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_team_status(sock_path: str) -> TestResult:
    """Test team.status returns valid data for our team."""
    result = TestResult("team.status")
    try:
        resp = _rpc_call(sock_path, "team.status", {"team_name": TEAM_NAME}, rid=3)
        if resp.get("ok"):
            result.success(f"Status: {json.dumps(resp.get('result', ''))[:200]}")
        else:
            result.failure(f"Status failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_team_send(sock_path: str) -> TestResult:
    """Test sending text to a specific agent."""
    result = TestResult("team.send")
    try:
        resp = _rpc_call(sock_path, "team.send", {
            "team_name": TEAM_NAME,
            "agent_name": "w1",
            "text": "echo hello\n",
        }, rid=4)
        if resp.get("ok"):
            result.success("Text sent to agent w1")
        else:
            result.failure(f"Send failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_team_broadcast(sock_path: str) -> TestResult:
    """Test broadcasting text to all agents."""
    result = TestResult("team.broadcast")
    try:
        resp = _rpc_call(sock_path, "team.broadcast", {
            "team_name": TEAM_NAME,
            "text": "echo broadcast-test\n",
        }, rid=5)
        if resp.get("ok"):
            result.success("Broadcast sent")
        else:
            result.failure(f"Broadcast failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_team_destroy(sock_path: str) -> TestResult:
    """Test team destruction and cleanup."""
    result = TestResult("team.destroy")
    try:
        resp = _rpc_call(sock_path, "team.destroy", {"team_name": TEAM_NAME}, rid=6)
        if resp.get("ok"):
            result.success(f"Team '{TEAM_NAME}' destroyed")
        else:
            result.failure(f"Destroy failed: {resp.get('error', resp)}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def test_team_not_found_after_destroy(sock_path: str) -> TestResult:
    """Verify team no longer exists after destroy."""
    result = TestResult("team.status (after destroy)")
    try:
        resp = _rpc_call(sock_path, "team.status", {"team_name": TEAM_NAME}, rid=7)
        if not resp.get("ok"):
            result.success("Correctly returns error for destroyed team")
        else:
            result.failure(f"Team still exists after destroy: {resp}")
    except Exception as e:
        result.failure(f"RPC error: {e}")
    return result


def main():
    print("=" * 60)
    print("  term-mesh Team RPC Tests")
    print("=" * 60)

    try:
        sock_path = _detect_socket()
    except RuntimeError as e:
        print(f"\n❌ {e}")
        sys.exit(1)

    print(f"  Socket: {sock_path}\n")

    # Ensure clean state
    _cleanup_team(sock_path)

    # Define test sequence (order matters for lifecycle tests)
    tests = [
        lambda: test_ping(sock_path),
        lambda: test_team_create(sock_path),
    ]

    # After create, wait for agent pane to initialize
    results = []
    for t in tests:
        results.append(t())

    # If create succeeded, wait briefly for pane setup then run remaining tests
    if results[-1].passed:
        time.sleep(2)  # wait for agent terminal pane to spawn
        lifecycle_tests = [
            lambda: test_team_list(sock_path),
            lambda: test_team_status(sock_path),
            lambda: test_team_send(sock_path),
            lambda: test_team_broadcast(sock_path),
            lambda: test_team_destroy(sock_path),
            lambda: test_team_not_found_after_destroy(sock_path),
        ]
        for t in lifecycle_tests:
            results.append(t())
    else:
        # Ensure cleanup even if create failed
        _cleanup_team(sock_path)

    # Report
    print()
    passed = 0
    failed = 0
    for r in results:
        icon = "✅" if r.passed else "❌"
        print(f"  {icon} {r.name}: {r.message}")
        if r.passed:
            passed += 1
        else:
            failed += 1

    print()
    print(f"  Results: {passed} passed, {failed} failed, {len(results)} total")
    print("=" * 60)

    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
