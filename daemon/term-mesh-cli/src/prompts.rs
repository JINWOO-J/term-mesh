//! Prompt templates for autonomous research agents.
//!
//! Extracted from x-agent SKILL.md (v1.3.0) — Research Agent Prompt.
//! Each agent runs an independent discovery loop, sharing findings via a
//! shared board file (stigmergy: indirect coordination through shared state).

/// Returns the depth instructions string for a given depth level.
fn depth_instructions(depth: &str) -> &'static str {
    match depth {
        "shallow" => "Quick scan only. Prioritize breadth over depth. 1-2 findings per round. Max ~3 files per round.",
        "exhaustive" => "Leave no stone unturned. Cross-reference findings across files. Verify every claim. Max ~15 files per round.",
        // "deep" is the default
        _ => "Follow promising leads 2 levels deep. Verify key findings with a second source. Max ~8 files per round.",
    }
}

/// Assembles a Research Agent prompt for autonomous multi-agent research.
///
/// # Arguments
/// - `topic`       — The research topic or question to investigate
/// - `board_path`  — Absolute path to the shared board JSONL file
/// - `agent_n`     — This agent's index (1-based)
/// - `total`       — Total number of parallel agents
/// - `depth`       — Depth level: "shallow", "deep", or "exhaustive"
/// - `budget`      — Maximum number of discovery rounds
/// - `round`       — Current round (used in board POST format)
/// - `web_allowed` — Whether WebSearch/WebFetch tools are permitted
/// - `focus`       — Optional focus area hint
pub fn research_prompt(
    topic: &str,
    board_path: &str,
    agent_n: u32,
    total: u32,
    depth: &str,
    budget: u32,
    web_allowed: bool,
    focus: Option<&str>,
) -> String {
    let focus_hint = match focus {
        Some(f) => format!("\nFocus area: {f}\n"),
        None => String::new(),
    };

    let web_tools = if web_allowed {
        "- WebSearch, WebFetch for external research\n"
    } else {
        ""
    };

    let depth_instr = depth_instructions(depth);

    format!(
        r#"## Autonomous Research: {topic}{focus_hint}
You are researcher-{agent_n}, one of {total} independent researchers.
Your peers are also writing findings to the shared board.

### Your Tools
- Read, Grep, Glob, Bash for code/file exploration
{web_tools}
### Shared Board (Stigmergy)
BOARD FILE: {board_path}

- To POST a finding: Bash("echo '{{json}}' >> {board_path}")
  Format: {{"agent":"researcher-{agent_n}","round":R,"finding":"...","source":"...","implication":"..."}}
- To READ peer findings: Bash("cat {board_path}")

### Discovery Loop

Run up to {budget} rounds. Each round:

1. **READ BOARD** — Check what peers have discovered
   - Bash("cat {board_path}")
   - If a peer's finding opens a new angle: explore it
   - If a peer's finding overlaps your current line: pivot to avoid duplication
   - If a peer's finding contradicts yours: investigate the discrepancy

2. **FRAME** — What is the most valuable question to explore next?
   - Round 1: derive from the topic directly
   - Round 2+: informed by your findings AND board contents

3. **EXPLORE** — Gather evidence for your current question
   - {depth_instr}
   - Cite every finding: file path, line number, URL, or inference

4. **POST** — Write your finding to the board
   - Bash("echo '{{\"agent\":\"researcher-{agent_n}\",\"round\":R,\"finding\":\"...\",\"source\":\"...\",\"implication\":\"...\"}}' >> {board_path}")
   - Only post genuinely useful discoveries, not every observation

5. **JUDGE** — Should you continue?
   - STOP if: your questions are answered + confidence is high + board shows convergence
   - CONTINUE if: budget remains + open questions exist or board suggests new angles

### Depth: {depth}
{depth_instr}

### Final Report

When done (STOP or budget exhausted), output:

## Findings
| # | Finding | Confidence | Source |
|---|---------|------------|--------|
(number each finding, HIGH/MEDIUM/LOW confidence, cite source)

## Key Insights
- (3-5 most important takeaways)

## Board Interactions
- (what you learned from the board, how it changed your direction)
- (which peer findings influenced your exploration)

## Open Questions
- (what you couldn't resolve within budget)

## Self-Assessment
- Rounds used: X/{budget}
- Thoroughness: (1-10)
- Confidence: CONFIDENT / UNCERTAIN
"#,
        topic = topic,
        focus_hint = focus_hint,
        agent_n = agent_n,
        total = total,
        web_tools = web_tools,
        board_path = board_path,
        budget = budget,
        depth = depth,
        depth_instr = depth_instr,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_research_prompt_basic() {
        let prompt = research_prompt(
            "How does the tab system work?",
            "/tmp/research/board.jsonl",
            1,
            3,
            "deep",
            5,
            false,
            None,
        );
        assert!(prompt.contains("researcher-1"));
        assert!(prompt.contains("/tmp/research/board.jsonl"));
        assert!(prompt.contains("Run up to 5 rounds"));
        assert!(prompt.contains("Follow promising leads 2 levels deep"));
        assert!(!prompt.contains("WebSearch"));
    }

    #[test]
    fn test_research_prompt_web_and_focus() {
        let prompt = research_prompt(
            "Security vulnerabilities",
            "/tmp/board.jsonl",
            2,
            4,
            "exhaustive",
            8,
            true,
            Some("authentication layer"),
        );
        assert!(prompt.contains("researcher-2"));
        assert!(prompt.contains("Focus area: authentication layer"));
        assert!(prompt.contains("WebSearch"));
        assert!(prompt.contains("Leave no stone unturned"));
    }

    #[test]
    fn test_research_prompt_shallow() {
        let prompt = research_prompt(
            "Quick overview",
            "/tmp/board.jsonl",
            1,
            1,
            "shallow",
            2,
            false,
            None,
        );
        assert!(prompt.contains("Quick scan only"));
    }
}
