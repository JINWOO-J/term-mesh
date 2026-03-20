# Squash WIP Commits

Squash consecutive WIP commits into clean, meaningful commits.

**Usage:**
- `/squash` — auto-detect WIP commits and squash into one
- `/squash --by-topic` — group WIP commits by scope/topic into separate commits
- `/squash --since <ref>` — squash all commits since `<ref>`
- `/squash --dry-run` — preview what would be squashed without changing anything

## Arguments

$ARGUMENTS — optional: `--by-topic`, `--since <ref>`, `--dry-run`, or combination

## Steps

### 1. Identify WIP commits

```bash
git log --oneline -30
```

Find the boundary: scan from HEAD backwards to find the last non-WIP commit. WIP commits match patterns: `WIP(`, `wip:`, `wip(`, or auto-commit messages like `wip: update N files`.

Report:
- Number of WIP commits found
- The base commit (last non-WIP)
- List of scopes/topics detected from `WIP(scope):` format

### 2. Analyze changes

```bash
git diff <base>..HEAD --stat
```

If `--dry-run` was specified, show the preview and stop.

### 3. Choose strategy

**Default (single squash):**
- Combine all WIP commits into one commit
- Generate a descriptive commit message based on the actual diff

**`--by-topic`:**
- Group WIP commits by their `WIP(scope)` prefix
- Create one clean commit per scope group
- Use `git reset --soft <base>` then selectively stage and commit by file groups

### 4. Execute squash

For single squash:
```bash
git reset --soft <base>
git commit -m "<generated message>"
```

For by-topic: reset soft, then for each topic group stage relevant files and commit separately.

### 5. Verify

```bash
git log --oneline -5
git diff <base>..HEAD --stat
```

Confirm the diff is identical before and after squash (no code changes lost).

## Commit Message Format

- Use conventional commits: `fix:`, `feat:`, `refactor:`, `chore:`, `docs:`
- If multiple types, use the dominant one
- Keep first line under 72 chars
- Add bullet points for details if 3+ distinct changes

## Safety

- NEVER force push automatically — only local squash
- Always verify diff equality before/after
- If on a shared branch (not main), warn before proceeding
- Keep `Co-Authored-By` if present in any squashed commit
