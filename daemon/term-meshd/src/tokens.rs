use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Scan interval for JSONL files.
const SCAN_INTERVAL: Duration = Duration::from_secs(5);

// ── Model Pricing (USD per million tokens) ──

struct ModelPricing {
    base_input: f64,
    cache_write_1h: f64,
    cache_read: f64,
    output: f64,
}

fn model_pricing(model: &str) -> ModelPricing {
    // Match by prefix to handle versioned model IDs
    if model.starts_with("claude-opus-4-6")
        || model.starts_with("claude-opus-4-5")
        || model.starts_with("claude-opus-4-20")
    {
        ModelPricing {
            base_input: 5.0,
            cache_write_1h: 10.0,
            cache_read: 0.5,
            output: 25.0,
        }
    } else if model.starts_with("claude-sonnet-4")
        || model.starts_with("claude-sonnet-3-5")
        || model.starts_with("claude-sonnet-3.5")
    {
        ModelPricing {
            base_input: 3.0,
            cache_write_1h: 6.0,
            cache_read: 0.3,
            output: 15.0,
        }
    } else if model.starts_with("claude-haiku") {
        ModelPricing {
            base_input: 1.0,
            cache_write_1h: 2.0,
            cache_read: 0.1,
            output: 5.0,
        }
    } else {
        // Default to Sonnet pricing for unknown models
        ModelPricing {
            base_input: 3.0,
            cache_write_1h: 6.0,
            cache_read: 0.3,
            output: 15.0,
        }
    }
}

// ── JSONL Parsing Structures ──

#[derive(Debug, Deserialize)]
struct JsonlLine {
    #[serde(rename = "type")]
    line_type: String,
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
    cwd: Option<String>,
    message: Option<AssistantMessage>,
}

#[derive(Debug, Deserialize)]
struct AssistantMessage {
    model: Option<String>,
    usage: Option<TokenUsage>,
}

#[derive(Debug, Clone, Deserialize)]
struct TokenUsage {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    cache_creation_input_tokens: u64,
    #[serde(default)]
    cache_read_input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    cache_creation: Option<CacheCreationBreakdown>,
}

#[derive(Debug, Clone, Deserialize)]
struct CacheCreationBreakdown {
    #[serde(default)]
    ephemeral_1h_input_tokens: u64,
}

// ── Aggregated Stats ──

/// Per-session usage stats for API/dashboard consumption.
#[derive(Debug, Clone, Serialize, Default)]
pub struct SessionUsageStats {
    pub session_id: String,
    pub project_path: String,
    pub model: String,
    pub input_tokens: u64,
    pub cache_write_tokens: u64,
    pub cache_read_tokens: u64,
    pub output_tokens: u64,
    pub api_calls: u64,
    pub cost_usd: f64,
    pub last_activity_ms: u64,
}

/// Snapshot of all sessions.
#[derive(Debug, Clone, Serialize)]
pub struct UsageSnapshot {
    pub sessions: Vec<SessionUsageStats>,
    pub total_cost_usd: f64,
    pub total_input_tokens: u64,
    pub total_output_tokens: u64,
    pub total_cache_read_tokens: u64,
    pub total_cache_write_tokens: u64,
}

// ── Tracker ──

struct TrackerState {
    sessions: HashMap<String, SessionUsageStats>,
    file_positions: HashMap<PathBuf, u64>,
    claude_projects_dir: PathBuf,
}

/// Tracks real API token usage by parsing Claude Code JSONL log files.
#[derive(Clone)]
pub struct UsageTracker {
    state: Arc<Mutex<TrackerState>>,
}

impl UsageTracker {
    pub fn new() -> Self {
        let home = dirs::home_dir().expect("no home directory");
        let claude_dir = home.join(".claude").join("projects");

        Self {
            state: Arc::new(Mutex::new(TrackerState {
                sessions: HashMap::new(),
                file_positions: HashMap::new(),
                claude_projects_dir: claude_dir,
            })),
        }
    }

    /// Start the background scanning loop. Returns self for chaining.
    pub fn start(self) -> Self {
        let tracker = self.clone();
        tokio::spawn(async move {
            // Initial scan
            if let Err(e) = tracker.scan_all() {
                tracing::warn!("Initial JSONL scan error: {e}");
            }
            let mut interval = tokio::time::interval(SCAN_INTERVAL);
            loop {
                interval.tick().await;
                if let Err(e) = tracker.scan_all() {
                    tracing::warn!("JSONL scan error: {e}");
                }
            }
        });
        self
    }

    /// Scan all JSONL files for new data.
    pub fn scan_all(&self) -> anyhow::Result<()> {
        let claude_dir = {
            self.state.lock().unwrap().claude_projects_dir.clone()
        };

        if !claude_dir.exists() {
            return Ok(());
        }

        for entry in std::fs::read_dir(&claude_dir)? {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            let project_dir = entry.path();
            self.scan_jsonl_files_in(&project_dir)?;

            // Scan subagent directories: <session-uuid>/subagents/*.jsonl
            for sub_entry in std::fs::read_dir(&project_dir)
                .into_iter()
                .flatten()
                .flatten()
            {
                if sub_entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    let subagent_dir = sub_entry.path().join("subagents");
                    if subagent_dir.exists() {
                        self.scan_jsonl_files_in(&subagent_dir)?;
                    }
                }
            }
        }
        Ok(())
    }

    fn scan_jsonl_files_in(&self, dir: &Path) -> anyhow::Result<()> {
        for entry in std::fs::read_dir(dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
                if let Err(e) = self.scan_file(&path) {
                    tracing::debug!("Error scanning {}: {e}", path.display());
                }
            }
        }
        Ok(())
    }

    fn scan_file(&self, path: &Path) -> anyhow::Result<()> {
        let metadata = std::fs::metadata(path)?;
        let file_len = metadata.len();

        let mut state = self.state.lock().unwrap();
        let offset = state.file_positions.get(path).copied().unwrap_or(0);

        // File truncated or rotated — reset
        if file_len < offset {
            state.file_positions.insert(path.to_path_buf(), 0);
            return Ok(());
        }

        // No new data
        if file_len == offset {
            return Ok(());
        }

        let file = std::fs::File::open(path)?;
        let mut reader = BufReader::new(file);
        reader.seek(SeekFrom::Start(offset))?;

        let mut line_buf = String::new();

        while reader.read_line(&mut line_buf)? > 0 {
            let trimmed = line_buf.trim();
            if !trimmed.is_empty() {
                if let Ok(entry) = serde_json::from_str::<JsonlLine>(trimmed) {
                    process_line(&mut state, &entry, path);
                }
            }
            line_buf.clear();
        }

        let new_offset = reader.stream_position()?;
        state.file_positions.insert(path.to_path_buf(), new_offset);
        Ok(())
    }

    /// Get a snapshot of all session usage data.
    pub fn snapshot(&self) -> UsageSnapshot {
        let state = self.state.lock().unwrap();
        let sessions: Vec<SessionUsageStats> = state.sessions.values().cloned().collect();

        let total_cost_usd = sessions.iter().map(|s| s.cost_usd).sum();
        let total_input_tokens = sessions.iter().map(|s| s.input_tokens).sum();
        let total_output_tokens = sessions.iter().map(|s| s.output_tokens).sum();
        let total_cache_read_tokens = sessions.iter().map(|s| s.cache_read_tokens).sum();
        let total_cache_write_tokens = sessions.iter().map(|s| s.cache_write_tokens).sum();

        UsageSnapshot {
            sessions,
            total_cost_usd,
            total_input_tokens,
            total_output_tokens,
            total_cache_read_tokens,
            total_cache_write_tokens,
        }
    }
}

fn process_line(state: &mut TrackerState, entry: &JsonlLine, file_path: &Path) {
    if entry.line_type != "assistant" {
        return;
    }

    let session_id = match &entry.session_id {
        Some(s) => s.clone(),
        None => return,
    };

    let message = match &entry.message {
        Some(m) => m,
        None => return,
    };

    let usage = match &message.usage {
        Some(u) => u.clone(),
        None => return,
    };

    let model = message
        .model
        .clone()
        .unwrap_or_else(|| "unknown".into());

    let project_path = entry.cwd.clone().unwrap_or_else(|| {
        decode_project_dir(file_path)
    });

    let cost = calculate_line_cost(&usage, &model);

    let stats = state
        .sessions
        .entry(session_id.clone())
        .or_insert_with(|| SessionUsageStats {
            session_id,
            project_path: project_path.clone(),
            model: model.clone(),
            ..Default::default()
        });

    stats.input_tokens += usage.input_tokens;
    stats.output_tokens += usage.output_tokens;
    stats.cache_read_tokens += usage.cache_read_input_tokens;

    if let Some(ref cc) = usage.cache_creation {
        stats.cache_write_tokens += cc.ephemeral_1h_input_tokens;
    } else {
        stats.cache_write_tokens += usage.cache_creation_input_tokens;
    }

    stats.api_calls += 1;
    stats.cost_usd += cost;
    stats.last_activity_ms = now_ms();

    // Update model to most recent
    if !model.is_empty() && model != "unknown" {
        stats.model = model;
    }
    // Update project_path if cwd is available
    if entry.cwd.is_some() {
        stats.project_path = project_path;
    }
}

fn calculate_line_cost(usage: &TokenUsage, model: &str) -> f64 {
    let pricing = model_pricing(model);
    let mtok = 1_000_000.0;

    let input_cost = (usage.input_tokens as f64 / mtok) * pricing.base_input;

    let cache_write_cost = if let Some(ref cc) = usage.cache_creation {
        (cc.ephemeral_1h_input_tokens as f64 / mtok) * pricing.cache_write_1h
    } else {
        (usage.cache_creation_input_tokens as f64 / mtok) * pricing.cache_write_1h
    };

    let cache_read_cost = (usage.cache_read_input_tokens as f64 / mtok) * pricing.cache_read;
    let output_cost = (usage.output_tokens as f64 / mtok) * pricing.output;

    input_cost + cache_write_cost + cache_read_cost + output_cost
}

/// Decode project directory name back to a path.
/// e.g., "-Users-jinwoo-work-tty-mesh" → "/Users/jinwoo/work/tty-mesh"
fn decode_project_dir(file_path: &Path) -> String {
    // Walk up to find the project directory under ~/.claude/projects/
    let mut path = file_path;
    loop {
        if let Some(parent) = path.parent() {
            if parent
                .file_name()
                .and_then(|n| n.to_str())
                .map(|n| n == "projects")
                .unwrap_or(false)
            {
                // path is the project directory
                let dir_name = path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("");
                return dir_name.replacen('-', "/", 1).replace('-', "/");
            }
            path = parent;
        } else {
            break;
        }
    }
    "unknown".to_string()
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
