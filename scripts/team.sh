#!/bin/bash
# term-mesh Team Agent CLI — thin wrapper around tm-agent
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Try the Rust binary first (in PATH via Resources/bin), then local build
if command -v tm-agent &>/dev/null; then
    exec tm-agent "$@"
elif [ -x "$SCRIPT_DIR/../daemon/target/release/tm-agent" ]; then
    exec "$SCRIPT_DIR/../daemon/target/release/tm-agent" "$@"
else
    echo "Error: tm-agent binary not found" >&2
    exit 1
fi
