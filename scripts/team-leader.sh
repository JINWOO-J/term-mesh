#!/bin/bash
# Team Leader Console — interactive REPL for commanding agents
# Launched automatically by TeamOrchestrator in the leader pane.
#
# Numbered shortcuts:
#   1 find the main entry point     — send to agent #1
#   2 refactor the login module     — send to agent #2
#   * report your status            — broadcast to all
#
# Also supports @name syntax:
#   @explorer find the main entry point
#   @all report your status
#   @status / @destroy / @help

SOCKET="$1"
TEAM="$2"

if [ -z "$SOCKET" ] || [ -z "$TEAM" ]; then
    echo "Usage: team-leader.sh <socket_path> <team_name>"
    exit 1
fi

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

AGENT_NAMES=()

rpc() {
    python3 -c "
import socket, json, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect(sys.argv[2])
except Exception as e:
    print(json.dumps({'ok': False, 'error': {'message': str(e)}}))
    sys.exit(0)
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

refresh_agents() {
    AGENT_NAMES=()
    local agents
    agents=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.status\",\"params\":{\"team_name\":\"$TEAM\"}}" | \
    python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    agents = data.get('result', {}).get('agents', [])
    for a in agents:
        print(a['name'])
except:
    pass
" 2>/dev/null)
    if [ -n "$agents" ]; then
        while IFS= read -r name; do
            AGENT_NAMES+=("$name")
        done <<< "$agents"
    fi
}

# Build the shortcut bar: [1:explorer 2:executor *:all]
shortcut_bar() {
    local bar=""
    for i in "${!AGENT_NAMES[@]}"; do
        local n=$((i+1))
        bar+="${GREEN}${n}${NC}:${AGENT_NAMES[$i]}  "
    done
    bar+="${YELLOW}*${NC}:all"
    echo -e "$bar"
}

send_to_agent() {
    local agent="$1"
    local msg="$2"
    REQ=$(python3 -c "
import json, sys
print(json.dumps({'jsonrpc':'2.0','id':1,'method':'team.send','params':{'team_name':sys.argv[1],'agent_name':sys.argv[2],'text':sys.argv[3]+'\n'}}))" "$TEAM" "$agent" "$msg")
    R=$(rpc "$REQ")
    ok=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',False))" 2>/dev/null)
    if [ "$ok" = "True" ]; then
        echo -e "${GREEN}-> $agent${NC}"
    else
        errmsg=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',{}).get('message','unknown'))" 2>/dev/null)
        echo -e "${RED}Failed ($agent): $errmsg${NC}"
    fi
}

broadcast_to_all() {
    local msg="$1"
    REQ=$(python3 -c "
import json, sys
print(json.dumps({'jsonrpc':'2.0','id':1,'method':'team.broadcast','params':{'team_name':sys.argv[1],'text':sys.argv[2]+'\n'}}))" "$TEAM" "$msg")
    R=$(rpc "$REQ")
    count=$(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('sent_count',0))" 2>/dev/null)
    echo -e "${GREEN}-> all ($count agent(s))${NC}"
}

show_banner() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  Team Leader Console: ${GREEN}${BOLD}$TEAM${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""
    sleep 2
    refresh_agents
    echo -e " $(shortcut_bar)"
    echo ""
    echo -e " ${DIM}Usage:  <number> <message>   or   * <message>${NC}"
    echo -e " ${DIM}        @name <message>  @status  @destroy  @help${NC}"
    echo ""
}

show_help() {
    refresh_agents
    echo ""
    echo -e "${CYAN}Shortcuts:${NC}"
    for i in "${!AGENT_NAMES[@]}"; do
        local n=$((i+1))
        echo -e "  ${BOLD}$n${NC} <message>  ${DIM}— send to ${AGENT_NAMES[$i]}${NC}"
    done
    echo -e "  ${BOLD}*${NC} <message>  ${DIM}— broadcast to all${NC}"
    echo ""
    echo -e "${CYAN}Commands:${NC}"
    for name in "${AGENT_NAMES[@]}"; do
        echo -e "  ${GREEN}@$name${NC} <message>"
    done
    echo -e "  ${YELLOW}@all${NC} <message>      ${DIM}— broadcast to all${NC}"
    echo -e "  ${YELLOW}@status${NC}              ${DIM}— show team status${NC}"
    echo -e "  ${YELLOW}@destroy${NC}             ${DIM}— destroy team and exit${NC}"
    echo -e "  ${YELLOW}@help${NC}                ${DIM}— show this help${NC}"
    echo ""
}

show_status() {
    refresh_agents
    R=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.status\",\"params\":{\"team_name\":\"$TEAM\"}}")
    echo "$R" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if data.get('ok'):
        r = data['result']
        print(f\"Team: {r['team_name']} ({r['agent_count']} agents)\")
        for i, a in enumerate(r['agents'], 1):
            print(f\"  {i}) {a['name']} ({a.get('agent_type','?')}) panel={a['panel_id'][:8]}...\")
    else:
        print(f\"Error: {data.get('error',{}).get('message','unknown')}\")
except Exception as e:
    print(f'Error: {e}')
" 2>/dev/null
    echo ""
    echo -e " $(shortcut_bar)"
}

show_banner

while true; do
    echo -ne "${CYAN}[$TEAM]${NC} > "
    if ! read -r line; then
        break
    fi

    [ -z "$line" ] && continue

    # --- Numbered shortcuts: "1 message", "2 message", "* message" ---
    if [[ "$line" =~ ^([0-9]+)[[:space:]]+(.+)$ ]]; then
        num="${BASH_REMATCH[1]}"
        msg="${BASH_REMATCH[2]}"
        idx=$((num - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#AGENT_NAMES[@]} ]; then
            send_to_agent "${AGENT_NAMES[$idx]}" "$msg"
        else
            echo -e "${RED}No agent #$num. Use 1-${#AGENT_NAMES[@]}${NC}"
        fi
        continue
    fi

    if [[ "$line" =~ ^\*[[:space:]]+(.+)$ ]]; then
        broadcast_to_all "${BASH_REMATCH[1]}"
        continue
    fi

    # --- @ syntax ---
    if [[ "$line" != @* ]]; then
        # Bare number without message
        if [[ "$line" =~ ^[0-9]+$ ]]; then
            echo -e "${DIM}Add a message: $line <your message>${NC}"
        else
            echo -e "${DIM}Use: <number> <message>, * <message>, or @name <message>${NC}"
        fi
        continue
    fi

    target="${line%% *}"
    target="${target#@}"
    message="${line#@$target }"
    [ "$message" = "@$target" ] && message=""

    case "$target" in
        help)
            show_help
            ;;
        status)
            show_status
            ;;
        destroy)
            echo -e "${YELLOW}Destroying team '$TEAM'...${NC}"
            rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"team.destroy\",\"params\":{\"team_name\":\"$TEAM\"}}" > /dev/null 2>&1
            echo -e "${GREEN}Team destroyed.${NC}"
            exit 0
            ;;
        all)
            if [ -z "$message" ]; then
                echo -e "${RED}Usage: @all <message>  or  * <message>${NC}"
                continue
            fi
            broadcast_to_all "$message"
            ;;
        *)
            if [ -z "$message" ]; then
                echo -e "${RED}Usage: @$target <message>${NC}"
                continue
            fi
            send_to_agent "$target" "$message"
            ;;
    esac
done
