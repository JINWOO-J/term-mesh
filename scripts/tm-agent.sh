#!/bin/bash
# tm-agent: ultra-lightweight RPC for team agents (~5ms vs Rust tm-agent ~2ms)
# Shell fallback when the Rust binary is not available.
# Bypasses Python startup entirely using macOS native nc (netcat).
#
# Usage:
#   tm-agent.sh report "task completed successfully"
#   tm-agent.sh ping "working on feature X"
#   tm-agent.sh msg "need help with Y"
#   tm-agent.sh msg "directed message" --to reviewer
#   tm-agent.sh task-done <task_id> "result summary"
#   tm-agent.sh task-start <task_id>
#   tm-agent.sh task-block <task_id> "reason"
#   tm-agent.sh heartbeat
#   tm-agent.sh status
#   tm-agent.sh inbox
#   tm-agent.sh tasks
#   tm-agent.sh batch '{"method":"team.agent.heartbeat",...}' '{"method":"team.task.list",...}'
#
# Environment:
#   TERMMESH_SOCKET    - socket path (auto-detected if unset)
#   TERMMESH_TEAM      - team name (default: live-team)
#   TERMMESH_AGENT_NAME - agent name (default: anonymous)

set -e

# Auto-detect socket
if [ -n "$TERMMESH_SOCKET" ]; then
    SOCK="$TERMMESH_SOCKET"
else
    for f in /tmp/term-mesh-debug-*.sock /tmp/term-mesh-debug.sock /tmp/term-mesh.sock /tmp/cmux.sock; do
        [ -S "$f" ] && SOCK="$f" && break
    done
fi
[ -z "$SOCK" ] && echo "Error: no socket found" >&2 && exit 1

TEAM="${TERMMESH_TEAM:-live-team}"
AGENT="${TERMMESH_AGENT_NAME:-anonymous}"

# JSON-escape a string in pure bash (no Python dependency)
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"    # backslash
    s="${s//\"/\\\"}"    # double quote
    s="${s//$'\n'/\\n}"  # newline
    s="${s//$'\r'/\\r}"  # carriage return
    s="${s//$'\t'/\\t}"  # tab
    printf '"%s"' "$s"
}

# Send RPC and print response
send_rpc() {
    local payload="$1"
    echo "$payload" | nc -U "$SOCK" -w 2 2>/dev/null | head -1
}

CMD="$1"
shift || { echo "Usage: tm-agent.sh <command> [args...]" >&2; exit 1; }

case "$CMD" in
    report)
        CONTENT=$(json_escape "$1")
        send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.report\",\"params\":{\"team_name\":\"$TEAM\",\"agent_name\":\"$AGENT\",\"content\":$CONTENT}}"
        ;;
    ping|heartbeat)
        SUMMARY=$(json_escape "${1:-alive}")
        send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.agent.heartbeat\",\"params\":{\"team_name\":\"$TEAM\",\"agent_name\":\"$AGENT\",\"summary\":$SUMMARY}}"
        ;;
    msg)
        CONTENT=$(json_escape "$1")
        TO_PARAM=""
        if [ "$2" = "--to" ] && [ -n "$3" ]; then
            TO_PARAM=",\"to\":\"$3\""
        fi
        send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.message.post\",\"params\":{\"team_name\":\"$TEAM\",\"from\":\"$AGENT\",\"content\":$CONTENT,\"type\":\"note\"$TO_PARAM}}"
        ;;
    task-start)
        [ -z "$1" ] && echo "Usage: tm-agent.sh task-start <task_id>" >&2 && exit 1
        send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.update\",\"params\":{\"team_name\":\"$TEAM\",\"task_id\":\"$1\",\"status\":\"in_progress\"}}"
        ;;
    task-done)
        [ -z "$1" ] && echo "Usage: tm-agent.sh task-done <task_id> [result]" >&2 && exit 1
        RESULT=$(json_escape "${2:-done}")
        send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.done\",\"params\":{\"team_name\":\"$TEAM\",\"task_id\":\"$1\",\"result\":$RESULT}}"
        ;;
    task-block)
        [ -z "$1" ] && echo "Usage: tm-agent.sh task-block <task_id> <reason>" >&2 && exit 1
        REASON=$(json_escape "${2:-blocked}")
        send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.block\",\"params\":{\"team_name\":\"$TEAM\",\"task_id\":\"$1\",\"blocked_reason\":$REASON}}"
        ;;
    status)
        send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.status\",\"params\":{\"team_name\":\"$TEAM\"}}"
        ;;
    inbox)
        send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.inbox\",\"params\":{\"team_name\":\"$TEAM\",\"agent_name\":\"$AGENT\"}}"
        ;;
    tasks)
        send_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.list\",\"params\":{\"team_name\":\"$TEAM\"}}"
        ;;
    batch)
        # Send multiple JSON-RPC payloads over a single connection
        PAYLOAD=""
        for arg in "$@"; do PAYLOAD+="$arg"$'\n'; done
        printf '%s' "$PAYLOAD" | nc -U "$SOCK" -w 2 2>/dev/null
        ;;
    raw)
        # Send raw JSON-RPC: tm-agent.sh raw '{"method":"team.status",...}'
        send_rpc "$1"
        ;;
    *)
        echo "Unknown command: $CMD" >&2
        echo "Commands: report, ping, heartbeat, msg, task-start, task-done, task-block, status, inbox, tasks, raw" >&2
        exit 1
        ;;
esac
