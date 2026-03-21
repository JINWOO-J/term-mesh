#!/bin/bash
# Copy Claude slash commands to app bundle with managed-file marker.
#
# This script prepends a "<!-- term-mesh-managed: ... -->" marker to each file.
# ClaudeCommandInstaller.swift checks this marker at runtime:
# - Files WITH the marker in ~/.claude/commands/ are overwritten on app update.
# - Files WITHOUT the marker are treated as user-customized and preserved.
#
# NOTE: The bundled files will differ from the source files by 1 line (the marker).
# Source of truth: .claude/commands/ in the git repo.
#
# IMPORTANT: When adding a new command to .claude/commands/ that should be
# distributed with the app, add its filename to the COMMANDS array below.
set -euo pipefail

SRC="${SRCROOT}/.claude/commands"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/claude-commands"

# 설치할 커맨드 파일 목록 — 새 커맨드 추가 시 여기에 파일명 추가
COMMANDS=(team.md team-up.md tm-bench.md tm-op.md)

mkdir -p "$DEST"

for f in "${COMMANDS[@]}"; do
    if [ -f "$SRC/$f" ]; then
        {
            echo "<!-- term-mesh-managed: do not remove this line -->"
            cat "$SRC/$f"
        } > "$DEST/$f"
        echo "Copied $f to bundle"
    else
        echo "warning: $SRC/$f not found, skipping"
    fi
done
