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

    read)
        AGENT="${1:?Usage: team.sh read <agent_name> [--lines N]}"
        shift
        LINES=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --lines) LINES="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        PARAMS="{\"team_name\":\"$TEAM\",\"agent_name\":\"$AGENT\""
        [ -n "$LINES" ] && PARAMS+=",\"lines\":$LINES"
        PARAMS+="}"
        R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.read\",\"params\":$PARAMS}")
        # Extract text field from JSON response for clean output
        echo "$R" | python3 -c "
import json, sys
try:
    r = json.load(sys.stdin)
    if 'result' in r and 'text' in r['result']:
        print(r['result']['text'])
    elif 'error' in r:
        print('Error:', r['error'].get('message', r['error']), file=sys.stderr)
        sys.exit(1)
    else:
        print(json.dumps(r, indent=2))
except: print(sys.stdin.read())
"
        ;;

    collect)
        LINES=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --lines) LINES="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        PARAMS="{\"team_name\":\"$TEAM\""
        [ -n "$LINES" ] && PARAMS+=",\"lines\":$LINES"
        PARAMS+="}"
        R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.collect\",\"params\":$PARAMS}")
        echo "$R" | pretty
        ;;

    wait)
        TIMEOUT=120
        INTERVAL=3
        WAIT_MODE="report"  # report | msg | any
        while [ $# -gt 0 ]; do
            case "$1" in
                --timeout) TIMEOUT="$2"; shift 2 ;;
                --interval) INTERVAL="$2"; shift 2 ;;
                --mode) WAIT_MODE="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        echo "Waiting for agents in team '$TEAM' (timeout: ${TIMEOUT}s, mode: $WAIT_MODE)..."

        # Get agent list for msg-based detection
        AGENT_LIST=""
        if [ "$WAIT_MODE" = "msg" ] || [ "$WAIT_MODE" = "any" ]; then
            AGENT_LIST=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.status\",\"params\":{\"team_name\":\"$TEAM\"}}" | python3 -c "
import json, sys
try:
    r = json.load(sys.stdin)
    agents = r.get('result', {}).get('agents', [])
    print(' '.join(a['name'] for a in agents))
except: print('')
")
        fi

        ELAPSED=0
        while [ $ELAPSED -lt $TIMEOUT ]; do
            REPORT_DONE="false"
            REPORT_PROGRESS="0/0"
            MSG_DONE="false"
            MSG_PROGRESS="0/0"

            # Check report-based completion
            if [ "$WAIT_MODE" = "report" ] || [ "$WAIT_MODE" = "any" ]; then
                R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.result.status\",\"params\":{\"team_name\":\"$TEAM\"}}")
                eval $(echo "$R" | python3 -c "
import json, sys
try:
    r = json.load(sys.stdin)
    res = r.get('result', {})
    done = res.get('completed', 0)
    total = res.get('total', 0)
    all_done = res.get('all_done', False)
    print(f'REPORT_PROGRESS=\"{done}/{total}\" REPORT_DONE=\"{\"true\" if all_done else \"false\"}\"')
except: print('REPORT_PROGRESS=\"0/0\" REPORT_DONE=\"false\"')
")
            fi

            # Check message-based completion (each agent has posted at least one message)
            if [ "$WAIT_MODE" = "msg" ] || [ "$WAIT_MODE" = "any" ]; then
                R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.message.list\",\"params\":{\"team_name\":\"$TEAM\"}}")
                eval $(echo "$R" | python3 -c "
import json, sys
agent_list = sys.argv[1].split()
try:
    r = json.load(sys.stdin)
    messages = r.get('result', {}).get('messages', [])
    senders = set(m.get('from', '') for m in messages)
    reported = sum(1 for a in agent_list if a in senders)
    total = len(agent_list)
    all_done = reported >= total and total > 0
    print(f'MSG_PROGRESS=\"{reported}/{total}\" MSG_DONE=\"{\"true\" if all_done else \"false\"}\"')
except: print('MSG_PROGRESS=\"0/0\" MSG_DONE=\"false\"')
" "$AGENT_LIST")
            fi

            # Determine overall status based on mode
            case "$WAIT_MODE" in
                report)
                    echo "  [$ELAPSED/${TIMEOUT}s] $REPORT_PROGRESS agents reported (report)"
                    [ "$REPORT_DONE" = "true" ] && { echo "All agents have reported results."; rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.result.collect\",\"params\":{\"team_name\":\"$TEAM\"}}" | pretty; exit 0; }
                    ;;
                msg)
                    echo "  [$ELAPSED/${TIMEOUT}s] $MSG_PROGRESS agents messaged (msg)"
                    [ "$MSG_DONE" = "true" ] && { echo "All agents have posted messages."; rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.message.list\",\"params\":{\"team_name\":\"$TEAM\"}}" | pretty; exit 0; }
                    ;;
                any)
                    echo "  [$ELAPSED/${TIMEOUT}s] report=$REPORT_PROGRESS msg=$MSG_PROGRESS (any)"
                    if [ "$REPORT_DONE" = "true" ]; then
                        echo "All agents have reported results."
                        rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.result.collect\",\"params\":{\"team_name\":\"$TEAM\"}}" | pretty
                        exit 0
                    fi
                    if [ "$MSG_DONE" = "true" ]; then
                        echo "All agents have posted messages."
                        rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.message.list\",\"params\":{\"team_name\":\"$TEAM\"}}" | pretty
                        exit 0
                    fi
                    ;;
            esac

            sleep "$INTERVAL"
            ELAPSED=$((ELAPSED + INTERVAL))
        done
        echo "Timeout: not all agents reported within ${TIMEOUT}s"
        rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.result.status\",\"params\":{\"team_name\":\"$TEAM\"}}" | pretty
        exit 1
        ;;

    report)
        TEXT="$*"
        [ -z "$TEXT" ] && { echo "Usage: team.sh report <text>"; exit 1; }
        # Detect agent name from env or require it
        AGENT_NAME="${CMUX_AGENT_NAME:-}"
        if [ -z "$AGENT_NAME" ]; then
            echo "Error: CMUX_AGENT_NAME not set. Use: CMUX_AGENT_NAME=explorer team.sh report ..."
            exit 1
        fi
        REQ=$(python3 -c "
import json, sys
print(json.dumps({'jsonrpc':'2.0','id':1,'method':'team.report','params':{
    'team_name': sys.argv[1],
    'agent_name': sys.argv[2],
    'content': sys.argv[3]
}}))" "$TEAM" "$AGENT_NAME" "$TEXT")
        R=$(rpc "$REQ")
        echo "$R" | pretty
        ;;

    msg)
        SUBCMD="${1:-list}"
        shift 2>/dev/null || true
        case "$SUBCMD" in
            send)
                # msg send [--to <recipient>] [--from <sender>] [--report] <text>
                FROM="${CMUX_AGENT_NAME:-anonymous}"
                TO=""
                DO_REPORT=""
                TEXT=""
                while [ $# -gt 0 ]; do
                    case "$1" in
                        --to) TO="$2"; shift 2 ;;
                        --from) FROM="$2"; shift 2 ;;
                        --report) DO_REPORT="true"; shift ;;
                        *) TEXT="$*"; break ;;
                    esac
                done
                [ -z "$TEXT" ] && { echo "Usage: team.sh msg send [--to X] [--from X] [--report] <text>"; exit 1; }
                REQ=$(python3 -c "
import json, sys
params = {
    'team_name': sys.argv[1], 'from': sys.argv[2], 'content': sys.argv[3], 'type': 'report'
}
if sys.argv[4]:
    params['to'] = sys.argv[4]
print(json.dumps({'jsonrpc':'2.0','id':1,'method':'team.message.post','params':params}))" "$TEAM" "$FROM" "$TEXT" "$TO")
                rpc "$REQ" | pretty
                # Also submit a report so wait can detect completion
                if [ "$DO_REPORT" = "true" ] && [ -n "$CMUX_AGENT_NAME" ]; then
                    REPORT_REQ=$(python3 -c "
import json, sys
print(json.dumps({'jsonrpc':'2.0','id':2,'method':'team.report','params':{
    'team_name': sys.argv[1], 'agent_name': sys.argv[2], 'content': sys.argv[3]
}}))" "$TEAM" "$CMUX_AGENT_NAME" "$TEXT")
                    rpc "$REPORT_REQ" > /dev/null
                fi
                ;;
            post)
                # msg post [--report] <from> <text>
                DO_REPORT=""
                if [ "$1" = "--report" ]; then
                    DO_REPORT="true"; shift
                fi
                FROM="${1:?Usage: team.sh msg post [--report] <from> <text>}"
                shift
                TEXT="$*"
                [ -z "$TEXT" ] && { echo "Usage: team.sh msg post [--report] <from> <text>"; exit 1; }
                REQ=$(python3 -c "
import json, sys
print(json.dumps({'jsonrpc':'2.0','id':1,'method':'team.message.post','params':{
    'team_name': sys.argv[1], 'from': sys.argv[2], 'content': sys.argv[3], 'type': 'report'
}}))" "$TEAM" "$FROM" "$TEXT")
                rpc "$REQ" | pretty
                # Also submit a report so wait can detect completion
                if [ "$DO_REPORT" = "true" ]; then
                    REPORT_REQ=$(python3 -c "
import json, sys
print(json.dumps({'jsonrpc':'2.0','id':2,'method':'team.report','params':{
    'team_name': sys.argv[1], 'agent_name': sys.argv[2], 'content': sys.argv[3]
}}))" "$TEAM" "$FROM" "$TEXT")
                    rpc "$REPORT_REQ" > /dev/null
                fi
                ;;
            list)
                FROM_FILTER=""
                LIMIT=""
                while [ $# -gt 0 ]; do
                    case "$1" in
                        --from) FROM_FILTER="$2"; shift 2 ;;
                        --limit) LIMIT="$2"; shift 2 ;;
                        *) shift ;;
                    esac
                done
                PARAMS="{\"team_name\":\"$TEAM\""
                [ -n "$FROM_FILTER" ] && PARAMS+=",\"from\":\"$FROM_FILTER\""
                [ -n "$LIMIT" ] && PARAMS+=",\"limit\":$LIMIT"
                PARAMS+="}"
                rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.message.list\",\"params\":$PARAMS}" | pretty
                ;;
            clear)
                rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.message.clear\",\"params\":{\"team_name\":\"$TEAM\"}}" | pretty
                ;;
            *)
                echo "Usage: team.sh msg <send|post|list|clear> [args]"
                echo ""
                echo "  send [--to X] [--from X] [--report] <text>   Send message (auto-detects sender)"
                echo "  post [--report] <from> <text>                Post message with explicit sender"
                echo "  list [--from X] [--limit N]                  List messages"
                echo "  clear                                        Clear all messages"
                ;;
        esac
        ;;

    task)
        SUBCMD="${1:-list}"
        shift 2>/dev/null || true
        case "$SUBCMD" in
            create)
                TITLE="$1"
                [ -z "$TITLE" ] && { echo "Usage: team.sh task create <title> [--assign agent]"; exit 1; }
                shift
                ASSIGNEE=""
                while [ $# -gt 0 ]; do
                    case "$1" in
                        --assign) ASSIGNEE="$2"; shift 2 ;;
                        *) shift ;;
                    esac
                done
                PARAMS="{\"team_name\":\"$TEAM\",\"title\":\"$TITLE\""
                [ -n "$ASSIGNEE" ] && PARAMS+=",\"assignee\":\"$ASSIGNEE\""
                PARAMS+="}"
                rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.create\",\"params\":$PARAMS}" | pretty
                ;;
            update)
                TASK_ID="${1:?Usage: team.sh task update <id> <status> [result]}"
                STATUS="${2:?Usage: team.sh task update <id> <status> [result]}"
                shift 2
                RESULT_TEXT="$*"
                PARAMS="{\"team_name\":\"$TEAM\",\"task_id\":\"$TASK_ID\",\"status\":\"$STATUS\""
                [ -n "$RESULT_TEXT" ] && PARAMS+=",\"result\":$(python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$RESULT_TEXT")"
                PARAMS+="}"
                rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.update\",\"params\":$PARAMS}" | pretty
                ;;
            list)
                FILTER_STATUS=""
                FILTER_ASSIGNEE=""
                while [ $# -gt 0 ]; do
                    case "$1" in
                        --status) FILTER_STATUS="$2"; shift 2 ;;
                        --assign) FILTER_ASSIGNEE="$2"; shift 2 ;;
                        *) shift ;;
                    esac
                done
                PARAMS="{\"team_name\":\"$TEAM\""
                [ -n "$FILTER_STATUS" ] && PARAMS+=",\"status\":\"$FILTER_STATUS\""
                [ -n "$FILTER_ASSIGNEE" ] && PARAMS+=",\"assignee\":\"$FILTER_ASSIGNEE\""
                PARAMS+="}"
                rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.list\",\"params\":$PARAMS}" | pretty
                ;;
            clear)
                rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.task.clear\",\"params\":{\"team_name\":\"$TEAM\"}}" | pretty
                ;;
            *)
                echo "Usage: team.sh task <create|update|list|clear> [args]"
                ;;
        esac
        ;;

    *)
        echo "cmux Team Agent CLI"
        echo ""
        echo "Usage: ./scripts/team.sh <command> [args]"
        echo ""
        echo "Commands:"
        echo "  create [N]                  Create team with N agents (default: 2)"
        echo "  send <agent> <text>         Send text to a specific agent"
        echo "  broadcast <text>            Send text to all agents"
        echo "  status                      Show team status"
        echo "  list                        List all teams"
        echo "  destroy                     Destroy the team"
        echo ""
        echo "Read & Collect (A):"
        echo "  read <agent> [--lines N]    Read agent's terminal screen"
        echo "  collect [--lines N]         Read all agents' terminal screens"
        echo ""
        echo "Results & Wait (B):"
        echo "  report <text>               Agent posts result (needs CMUX_AGENT_NAME)"
        echo "  wait [--timeout N] [--mode M]  Wait for agents (mode: report|msg|any)"
        echo ""
        echo "Messages (C):"
        echo "  msg send [--to X] [--from X] [--report] <text>  Send message (auto sender)"
        echo "  msg post [--report] <from> <text>               Post message (explicit sender)"
        echo "  msg list [--from X] [--limit N]                 List messages"
        echo "  msg clear                                       Clear all messages"
        echo ""
        echo "Task Board (D):"
        echo "  task create <title> [--assign agent]   Create a task"
        echo "  task update <id> <status> [result]     Update task status"
        echo "  task list [--status X] [--assign X]    List tasks"
        echo "  task clear                             Clear all tasks"
        echo ""
        echo "Environment:"
        echo "  CMUX_SOCKET=$SOCKET"
        echo "  CMUX_TEAM=$TEAM"
        echo "  CMUX_WORKDIR=$WORKDIR"
        echo "  CMUX_AGENT_NAME=(agent name, for report)"
        ;;
esac
