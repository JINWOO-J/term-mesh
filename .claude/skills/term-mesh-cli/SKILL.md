---
name: term-mesh-cli
description: Control term-mesh windows, workspaces, terminal panes, and browser splits from the CLI. Use when running inside term-mesh and you need to open a browser split (e.g. to view a local dashboard, preview web output, or inspect a page), evaluate JavaScript in an open browser, navigate/click/snapshot web pages, or manage panes and surfaces programmatically. Triggered by requests like "open a browser split", "view the dashboard in a split", "run JS in the browser panel", "click this on the page", or any task that needs to observe/manipulate a webpage from inside term-mesh.
metadata:
  version: "1.0.0"
---

# term-mesh CLI

`term-mesh` is a terminal emulator with first-class support for browser splits (WKWebView-based panels living alongside terminals). When Claude is running inside term-mesh, it can open browser panels, evaluate JavaScript in them, navigate pages, click elements, and tear them down — all via the `term-mesh` CLI.

## Detect you are inside term-mesh

```bash
[ -n "$TERMMESH_SURFACE_ID" ] && echo "inside term-mesh"
# or check the socket
[ -S /tmp/term-mesh.sock ] && echo "daemon running"
```

If neither is true, `term-mesh` CLI commands will fail with a connection error — use a different approach (e.g., `open` to launch Safari).

## Opening a browser split

```bash
# Preferred: one command, opens a new browser split to the right
term-mesh new-split right --type browser --url http://localhost:9876
# → "OK surface:N workspace:M"

# Alternative (same effect, different syntax)
term-mesh new-pane --type browser --direction right --url http://localhost:9876

# Reuse-or-open: if a browser pane already exists, navigate it; otherwise open new
term-mesh browser open http://localhost:9876
```

Direction: `left`, `right`, `up`, or `down`.

## Finding browser surfaces

```bash
# All panes and their surface refs
term-mesh --json list-panes

# Surfaces in a specific pane (with type: terminal|browser)
term-mesh --json list-pane-surfaces --pane pane:N
```

Parse with `python3 -c "import sys,json; d=json.load(sys.stdin); ..."` to extract `surface:N` refs.

## Evaluating JavaScript in a browser

```bash
# Value is printed directly (no --json needed)
term-mesh browser eval --surface surface:N 'document.title'
# → "Term-Mesh Dashboard"

term-mesh browser eval --surface surface:N 'document.getElementById("status").textContent'
# → "live"

term-mesh browser eval --surface surface:N '1 + 2'
# → 3

term-mesh browser eval --surface surface:N 'JSON.stringify({ok: window.poll !== undefined})'
# → {"ok":true}
```

For structured output, add `--json`:
```bash
term-mesh --json browser eval --surface surface:N 'document.title'
# → {"value": "Term-Mesh Dashboard", "surface_ref": "surface:N", ...}
```

**Async patterns**: `browser eval` runs synchronously and returns the script's return value. To test async code, assign to a global and poll:
```bash
term-mesh browser eval --surface surface:N 'void(fetch("/api/x").then(r=>r.ok).then(ok=>{window._r=ok}))'
sleep 1
term-mesh browser eval --surface surface:N 'window._r'
```

## Navigation

```bash
term-mesh browser navigate https://example.com --surface surface:N
term-mesh browser back --surface surface:N
term-mesh browser forward --surface surface:N
term-mesh browser reload --surface surface:N
term-mesh --json browser get-url --surface surface:N
```

## Inspecting page structure

```bash
# ARIA-tree snapshot — returns heading/button/link refs like e42
term-mesh browser snapshot --surface surface:N
```

Output is an indented accessibility tree. Use the `[ref=e42]` IDs with `browser click`.

## Clicking and interacting

```bash
# CSS selector
term-mesh browser click "button[data-action='save']" --surface surface:N

# Snapshot ref
term-mesh browser click "e42" --surface surface:N

# Text input
term-mesh browser type "input[name='q']" "search query" --surface surface:N
term-mesh browser fill "input[name='q']" "new value" --surface surface:N   # empties then types
term-mesh browser press "Enter" --surface surface:N
```

## Waiting

```bash
# Wait for page to finish loading
term-mesh browser wait --load-state complete --surface surface:N --timeout-ms 5000

# Wait for a selector to appear
term-mesh browser wait --selector ".loaded" --surface surface:N

# Wait for text
term-mesh browser wait --text "Success" --surface surface:N
```

## Closing

```bash
# Close the surface AND collapse the pane (no empty terminal left behind)
term-mesh close-surface --surface surface:N --close-pane

# Close just the surface (if the pane has other surfaces, they stay)
term-mesh close-surface --surface surface:N
```

**Key gotcha**: without `--close-pane`, closing the only surface in a pane may cause a new terminal surface to auto-spawn. Use `--close-pane` when you want the pane itself gone.

## Typical workflow: test a local dashboard

```bash
# 1. Open
term-mesh new-split right --type browser --url http://localhost:9876
# → OK surface:8 ...

# 2. Verify it loaded
term-mesh browser wait --load-state complete --surface surface:8
STATUS=$(term-mesh browser eval --surface surface:8 'document.getElementById("status").textContent')
echo "Status: $STATUS"

# 3. Interact
term-mesh browser click "button[data-preset='devOps']" --surface surface:8

# 4. Check result
ACTIVE=$(term-mesh browser eval --surface surface:8 \
  'document.querySelector(".preset-switcher .active")?.textContent')
echo "Active preset: $ACTIVE"

# 5. Clean up
term-mesh close-surface --surface surface:8 --close-pane
```

## Typical workflow: debug a JS error in a page

```bash
# After making changes to web code, reload and check for errors
term-mesh browser reload --surface surface:N
sleep 1

# Check if a specific function is defined (catches deleted-function bugs)
term-mesh browser eval --surface surface:N 'typeof updateMonitor'
# → "function" (good) or "undefined" (broken)

# Check current error state
term-mesh browser eval --surface surface:N \
  'JSON.stringify({status: document.getElementById("status")?.textContent})'
```

## Notes

- `term-mesh` binary location: usually `/Applications/term-mesh.app/Contents/Resources/bin/term-mesh` or `~/bin/term-mesh` (symlink). Must be on PATH.
- Browser panels are WKWebView — no separate browser process. `localhost` URLs work without CORS issues.
- `browser eval` scripts run in the page context. `window` refers to the page's window.
- The `--surface` handle accepts refs (`surface:N`), UUIDs, or indexes.
- For scripting, prefer `--json` output and parse with `python3 -c 'import sys,json;...'`.
- Ref IDs (`surface:N`, `pane:N`) are per-window and stable within a session, but change across app restarts.

## When NOT to use

- If not running inside term-mesh (no socket) — use `open` to launch Safari/Chrome, or Playwright MCP if available.
- For heavy browser automation with network interception, screenshots, or video — use Playwright MCP.
- For quick `curl`-style HTTP checks — just use `curl`, don't open a browser panel.
