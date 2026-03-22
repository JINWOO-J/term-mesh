# Sentry — sentry-cli wrapper for issue tracking, releases, and debug symbols

Lightweight sentry-cli integration. No plugins, no MCP overhead — just direct CLI calls.

**Usage:**
- `/sentry issues` — list/resolve/mute issues
- `/sentry releases` — create/finalize/list releases
- `/sentry dsym` — upload dSYM debug files
- `/sentry events` — list recent events
- `/sentry info` — check config and auth status

## Arguments

$ARGUMENTS — subcommand: `issues`, `releases`, `dsym`, `events`, `info`

## Routing

Parse the first word of `$ARGUMENTS`:
- `issues` → Step 2a
- `releases` → Step 2b
- `dsym` → Step 2c
- `events` → Step 2d
- `info` → Step 2e
- (empty or `help`) → Show usage table above and stop

## Steps

### 1. Environment check

```bash
which sentry-cli || echo "ERROR: sentry-cli not installed. Run: brew install getsentry/tools/sentry-cli"
sentry-cli info 2>&1 | head -10
```

Config is loaded from two `.sentryclirc` files:
- `~/.sentryclirc` — auth token (global, shared across all projects)
- `<project>/.sentryclirc` — org and project defaults (per-project)

Verify `sentry-cli info` shows valid auth and correct org/project.
If auth fails or org/project is `-`, guide the user:
```
# Global auth (~/.sentryclirc):
[auth]
token=sntrys_...

# Project defaults (<project>/.sentryclirc):
[defaults]
org=your-org
project=your-project
```
Then stop.

### 2a. Subcommand: `issues`

Remaining args after `issues` are passed as filters.

```bash
# List unresolved issues (default)
sentry-cli issues list

# With status filter: -s resolved | unresolved | muted
sentry-cli issues list -s unresolved

# Resolve specific issues
sentry-cli issues resolve <ISSUE_ID>

# Mute specific issues
sentry-cli issues mute <ISSUE_ID>
```

- If no extra args: list unresolved issues
- If arg is a number: show that issue's details
- If arg starts with `resolve` or `mute`: run the corresponding action
- Present results in a readable table format

### 2b. Subcommand: `releases`

```bash
# List recent releases
sentry-cli releases list

# Propose version from git
sentry-cli releases propose-version

# Create + finalize a release (full flow)
VERSION=$(sentry-cli releases propose-version)
sentry-cli releases new "$VERSION"
sentry-cli releases set-commits "$VERSION" --auto
sentry-cli releases finalize "$VERSION"

# Show release info
sentry-cli releases info <VERSION>
```

Parse remaining args:
- `list` → list releases
- `new` or `create` → full release flow (propose → new → set-commits → finalize)
- `info <VERSION>` → show release details
- (empty) → list releases

### 2c. Subcommand: `dsym`

Upload dSYM/DWARF debug symbols for crash symbolication.

```bash
# Find dSYM in DerivedData
DSYM_PATH=$(find ~/Library/Developer/Xcode/DerivedData -path "*/term-mesh*.app.dSYM" -print -quit 2>/dev/null)

# Upload
sentry-cli debug-files upload "$DSYM_PATH"

# Check a specific file
sentry-cli debug-files check "$DSYM_PATH"
```

Parse remaining args:
- (empty) → auto-find dSYM from DerivedData and upload
- `check` → find and check without uploading
- `<PATH>` → upload the specified path directly

### 2d. Subcommand: `events`

```bash
sentry-cli events list
```

Show recent events in a readable format. Highlight errors and crashes.

### 2e. Subcommand: `info`

```bash
sentry-cli info --config-status-json
```

Parse and display:
- Auth status (valid/expired token)
- Organization and project
- DSN
- Server URL

## Safety

- **NEVER** print, log, or commit `SENTRY_AUTH_TOKEN` values
- **NEVER** include tokens in commit messages or PR descriptions
- When displaying config, mask token values (show only last 4 chars)
- If a command fails with 401, suggest checking token validity — do not retry with different credentials
