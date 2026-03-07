#!/bin/bash
# cmux Team Agent CLI
# Usage:
#   ./scripts/team.sh create [agent_count]   — create team with N agents (default: 2)
#   ./scripts/team.sh send <agent> <text>    — send text to an agent
#   ./scripts/team.sh broadcast <text>       — broadcast to all agents
#   ./scripts/team.sh status                 — show team status
#   ./scripts/team.sh destroy                — destroy the team
#   ./scripts/team.sh list                   — list all teams
#
# Environment:
#   CMUX_SOCKET  — socket path (default: auto-detect)
#   CMUX_TEAM    — team name (default: live-team)

TEAM="${CMUX_TEAM:-live-team}"
WORKDIR="${CMUX_WORKDIR:-$HOME/work/project/cmux}"

# Auto-detect socket — try each candidate and verify it accepts connections
socket_ok() {
    local path="$1"
    python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.settimeout(1)
    s.connect('$path')
    s.close()
except:
    exit(1)
" 2>/dev/null
}

SOCKET=""
if [ -n "$CMUX_SOCKET" ] && socket_ok "$CMUX_SOCKET"; then
    SOCKET="$CMUX_SOCKET"
else
    for candidate in $(ls /tmp/cmux.sock /tmp/cmux-debug.sock /tmp/cmux-debug-*.sock 2>/dev/null); do
        if [ -S "$candidate" ] && socket_ok "$candidate"; then
            SOCKET="$candidate"
            break
        fi
    done
fi

if [ -z "$SOCKET" ]; then
    echo "Error: No connectable cmux socket found."
    echo "Start the app first or set CMUX_SOCKET."
    echo ""
    echo "Available sockets:"
    ls /tmp/cmux*.sock 2>/dev/null || echo "  (none)"
    exit 1
fi

rpc() {
    python3 -c "
import socket, json, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[2])
req = json.loads(sys.argv[1])
sock.sendall((json.dumps(req) + '\n').encode())
resp = b''
sock.settimeout(5)
try:
    while b'\n' not in resp:
        resp += sock.recv(4096)
except socket.timeout:
    pass
sock.close()
print(resp.decode().strip() if resp else '{}')
" "$1" "$SOCKET"
}

pretty() {
    python3 -m json.tool 2>/dev/null || cat
}

CMD="${1:-help}"
shift 2>/dev/null || true

case "$CMD" in
    create)
        # Parse flags
        LEADER_MODE="repl"
        COUNT=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --claude-leader) LEADER_MODE="claude"; shift ;;
                *) [ -z "$COUNT" ] && COUNT="$1"; shift ;;
            esac
        done
        COUNT="${COUNT:-2}"

        AGENTS="["
        COLORS=("green" "blue" "yellow" "magenta" "cyan" "red")
        NAMES=("explorer" "executor" "reviewer" "debugger" "writer" "tester")
        for ((i=0; i<COUNT; i++)); do
            [ $i -gt 0 ] && AGENTS+=","
            NAME="${NAMES[$i]:-agent-$i}"
            COLOR="${COLORS[$((i % 6))]}"
            AGENTS+="{\"name\":\"$NAME\",\"model\":\"sonnet\",\"agent_type\":\"$NAME\",\"color\":\"$COLOR\"}"
        done
        AGENTS+="]"

        # Clean up existing team first (short timeout)
        python3 -c "
import socket, json, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.settimeout(2)
    sock.connect(sys.argv[1])
    req = json.dumps({'jsonrpc':'2.0','id':0,'method':'team.destroy','params':{'team_name':'$TEAM'}})
    sock.sendall((req + '\n').encode())
    sock.recv(4096)
except: pass
finally: sock.close()
" "$SOCKET" 2>/dev/null
        sleep 0.5

        echo "Creating team '$TEAM' with $COUNT agent(s) [leader: $LEADER_MODE]..."
        echo "Socket: $SOCKET"
        R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.create\",\"params\":{\"team_name\":\"$TEAM\",\"working_directory\":\"$WORKDIR\",\"leader_session_id\":\"leader-$$\",\"leader_mode\":\"$LEADER_MODE\",\"agents\":$AGENTS}}")
        echo "$R" | pretty
        echo ""
        echo "Commands:"
        echo "  ./scripts/team.sh send <agent> 'your message'"
        echo "  ./scripts/team.sh broadcast 'message to all'"
        echo "  ./scripts/team.sh status"
        echo "  ./scripts/team.sh destroy"
        ;;

    send)
        AGENT="${1:?Usage: team.sh send <agent_name> <text>}"
        shift
        TEXT="$*"
        [ -z "$TEXT" ] && { echo "Usage: team.sh send <agent_name> <text>"; exit 1; }
        REQ=$(python3 -c "
import json, sys
print(json.dumps({'jsonrpc':'2.0','id':1,'method':'team.send','params':{'team_name':sys.argv[1],'agent_name':sys.argv[2],'text':sys.argv[3]+'\n'}}))" "$TEAM" "$AGENT" "$TEXT")
        R=$(rpc "$REQ")
        echo "$R" | pretty
        ;;

    broadcast)
        TEXT="$*"
        [ -z "$TEXT" ] && { echo "Usage: team.sh broadcast <text>"; exit 1; }
        REQ=$(python3 -c "
import json, sys
print(json.dumps({'jsonrpc':'2.0','id':1,'method':'team.broadcast','params':{'team_name':sys.argv[1],'text':sys.argv[2]+'\n'}}))" "$TEAM" "$TEXT")
        R=$(rpc "$REQ")
        echo "$R" | pretty
        ;;

    status)
        R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.status\",\"params\":{\"team_name\":\"$TEAM\"}}")
        echo "$R" | pretty
        ;;

    list)
        R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.list\",\"params\":{}}")
        echo "$R" | pretty
        ;;

    destroy)
        echo "Destroying team '$TEAM'..."
        R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.destroy\",\"params\":{\"team_name\":\"$TEAM\"}}")
        echo "$R" | pretty
        ;;

    *)
        echo "cmux Team Agent CLI"
        echo ""
        echo "Usage: ./scripts/team.sh <command> [args]"
        echo ""
        echo "Commands:"
        echo "  create [N]              Create team with N agents (default: 2)"
        echo "  send <agent> <text>     Send text to a specific agent"
        echo "  broadcast <text>        Send text to all agents"
        echo "  status                  Show team status"
        echo "  list                    List all teams"
        echo "  destroy                 Destroy the team"
        echo ""
        echo "Environment:"
        echo "  CMUX_SOCKET=$SOCKET"
        echo "  CMUX_TEAM=$TEAM"
        echo "  CMUX_WORKDIR=$WORKDIR"
        ;;
esac
