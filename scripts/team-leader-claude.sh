#!/bin/bash
# Team Leader Claude — runs Claude as an interactive team leader
# The user talks to this Claude to direct agent work.
#
# Usage: team-leader-claude.sh <socket_path> <team_name>

SOCKET="$1"
TEAM="$2"

if [ -z "$SOCKET" ] || [ -z "$TEAM" ]; then
    echo "Usage: team-leader-claude.sh <socket_path> <team_name>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Detect claude binary
CLAUDE=""
if [ -x "$HOME/.local/bin/claude" ]; then
    CLAUDE="$HOME/.local/bin/claude"
elif command -v claude &>/dev/null; then
    CLAUDE="$(command -v claude)"
fi

if [ -z "$CLAUDE" ]; then
    echo "Error: claude binary not found"
    exit 1
fi

# Wait for agents to be ready (Claude binary takes ~5s to initialize)
sleep 5

# Fetch agent list
AGENTS_JSON=$(python3 -c "
import socket, json, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect('$SOCKET')
except:
    print('[]')
    sys.exit(0)
req = json.dumps({'jsonrpc':'2.0','id':1,'method':'team.status','params':{'team_name':'$TEAM'}})
sock.sendall((req + '\n').encode())
resp = b''
sock.settimeout(5)
try:
    while b'\n' not in resp:
        resp += sock.recv(4096)
except socket.timeout:
    pass
sock.close()
try:
    data = json.loads(resp.decode().strip())
    agents = data.get('result', {}).get('agents', [])
    for a in agents:
        print(f\"{a['name']} ({a.get('agent_type','?')})\")
except:
    pass
" 2>/dev/null)

# Build agent list for prompt
AGENT_LIST=""
AGENT_NUM=1
while IFS= read -r agent_line; do
    [ -z "$agent_line" ] && continue
    AGENT_LIST+="  ${AGENT_NUM}. ${agent_line}"$'\n'
    ((AGENT_NUM++))
done <<< "$AGENTS_JSON"

# System prompt for the leader Claude
SYSTEM_PROMPT="You are the TEAM LEADER for team '${TEAM}'. You direct a group of Claude agent workers running in terminal split panes.

## Your Agents
${AGENT_LIST}
## How to Command Agents

Send a task to a specific agent:
\`\`\`bash
${SCRIPT_DIR}/team.sh send <agent_name> '<your instruction>'
\`\`\`

Broadcast to all agents:
\`\`\`bash
${SCRIPT_DIR}/team.sh broadcast '<your instruction>'
\`\`\`

Check team status:
\`\`\`bash
${SCRIPT_DIR}/team.sh status
\`\`\`

Environment variable is pre-set: CMUX_SOCKET=${SOCKET}

## Your Role

1. When the user gives you a task, break it down and delegate subtasks to appropriate agents
2. Use the agent names and their specialties to route work effectively
3. Monitor progress by checking status or asking agents to report
4. Coordinate between agents when tasks have dependencies
5. Report back to the user with results and summaries

## Guidelines

- Always use the team.sh commands via Bash to communicate with agents
- Be concise in your instructions to agents — they are Claude instances that understand context
- When delegating, include enough context for the agent to work independently
- You can send follow-up instructions if the first message wasn't clear enough
- Prefer parallel work: send independent tasks to multiple agents simultaneously"

export CMUX_SOCKET="$SOCKET"
export CMUX_TEAM="$TEAM"
# Must unset CLAUDECODE — cmux app may inherit it from a parent Claude session,
# and Claude Code refuses to start inside another CLAUDECODE session.
unset CLAUDECODE

# Write system prompt to temp file (avoids shell escaping issues with multiline text)
PROMPT_FILE=$(mktemp /tmp/cmux-leader-prompt-XXXXXX)
echo "$SYSTEM_PROMPT" > "$PROMPT_FILE"
trap "rm -f '$PROMPT_FILE'" EXIT

# Launch Claude as the team leader
exec "$CLAUDE" \
    --system-prompt "$(cat "$PROMPT_FILE")" \
    --dangerously-skip-permissions
