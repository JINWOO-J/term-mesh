use notify::{Config, Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde::Serialize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc;

/// A single file event record.
#[derive(Debug, Clone, Serialize)]
pub struct FileEvent {
    pub path: String,
    pub kind: String, // "create" | "modify" | "remove" | "access"
    pub timestamp_ms: u64,
}

/// Aggregated heatmap entry for a file/directory.
#[derive(Debug, Clone, Serialize)]
pub struct HeatmapEntry {
    pub path: String,
    pub event_count: u64,
    pub last_event_ms: u64,
}

/// Snapshot of the file heatmap state.
#[derive(Debug, Clone, Serialize)]
pub struct HeatmapSnapshot {
    pub timestamp_ms: u64,
    pub watched_paths: Vec<String>,
    pub top_files: Vec<HeatmapEntry>,
    pub recent_events: Vec<FileEvent>,
}

/// Shared state for the file watcher.
#[derive(Clone)]
pub struct WatcherHandle {
    state: Arc<Mutex<WatcherState>>,
    command_tx: mpsc::Sender<WatcherCommand>,
}

struct WatcherState {
    event_counts: HashMap<String, u64>,
    last_event_times: HashMap<String, u64>,
    recent_events: Vec<FileEvent>,
    watched_paths: Vec<String>,
}

enum WatcherCommand {
    Watch(String),
    Unwatch(String),
}

impl WatcherHandle {
    pub fn watch_path(&self, path: &str) {
        // Update state immediately so snapshot reflects it right away
        {
            let mut state = self.state.lock().unwrap();
            if state.watched_paths.iter().any(|p| p == path) {
                return; // Already watching
            }
            state.watched_paths.push(path.to_string());
        }
        // Send command to the watcher thread to actually start watching
        let _ = self.command_tx.try_send(WatcherCommand::Watch(path.to_string()));
    }

    pub fn unwatch_path(&self, path: &str) {
        {
            let mut state = self.state.lock().unwrap();
            state.watched_paths.retain(|p| p != path);
        }
        let _ = self.command_tx.try_send(WatcherCommand::Unwatch(path.to_string()));
    }

    pub fn snapshot(&self) -> HeatmapSnapshot {
        let state = self.state.lock().unwrap();
        let now = now_ms();

        // Top 10 files by event count
        let mut entries: Vec<HeatmapEntry> = state
            .event_counts
            .iter()
            .map(|(path, &count)| HeatmapEntry {
                path: path.clone(),
                event_count: count,
                last_event_ms: state.last_event_times.get(path).copied().unwrap_or(0),
            })
            .collect();
        entries.sort_by(|a, b| b.event_count.cmp(&a.event_count));
        entries.truncate(10);

        // Last 50 events
        let recent = state
            .recent_events
            .iter()
            .rev()
            .take(50)
            .cloned()
            .collect();

        HeatmapSnapshot {
            timestamp_ms: now,
            watched_paths: state.watched_paths.clone(),
            top_files: entries,
            recent_events: recent,
        }
    }
}

/// Start the file watcher background task.
pub fn start_watcher() -> WatcherHandle {
    let state = Arc::new(Mutex::new(WatcherState {
        event_counts: HashMap::new(),
        last_event_times: HashMap::new(),
        recent_events: Vec::new(),
        watched_paths: Vec::new(),
    }));

    let (cmd_tx, mut cmd_rx) = mpsc::channel::<WatcherCommand>(256);
    let (event_tx, mut event_rx) = mpsc::channel::<Event>(512);

    // Spawn the notify watcher in a blocking thread
    std::thread::spawn(move || {
        let tx = event_tx;
        let mut watcher: RecommendedWatcher = Watcher::new(
            move |res: Result<Event, notify::Error>| {
                if let Ok(event) = res {
                    let _ = tx.blocking_send(event);
                }
            },
            Config::default(),
        )
        .expect("failed to create watcher");

        // Process commands
        while let Some(cmd) = cmd_rx.blocking_recv() {
            match cmd {
                WatcherCommand::Watch(path) => {
                    tracing::info!("watching: {path}");
                    if let Err(e) =
                        watcher.watch(PathBuf::from(&path).as_path(), RecursiveMode::Recursive)
                    {
                        tracing::error!("failed to watch {path}: {e}");
                    }
                }
                WatcherCommand::Unwatch(path) => {
                    tracing::info!("unwatching: {path}");
                    let _ = watcher.unwatch(PathBuf::from(&path).as_path());
                }
            }
        }
    });

    // Process events in async context
    let state_for_events = state.clone();
    tokio::spawn(async move {
        while let Some(event) = event_rx.recv().await {
            let kind_str = match event.kind {
                EventKind::Create(_) => "create",
                EventKind::Modify(_) => "modify",
                EventKind::Remove(_) => "remove",
                EventKind::Access(_) => "access",
                _ => continue,
            };

            let now = now_ms();
            let mut state = state_for_events.lock().unwrap();

            for path in &event.paths {
                let path_str = path.to_string_lossy().to_string();

                *state.event_counts.entry(path_str.clone()).or_insert(0) += 1;
                state.last_event_times.insert(path_str.clone(), now);

                state.recent_events.push(FileEvent {
                    path: path_str,
                    kind: kind_str.to_string(),
                    timestamp_ms: now,
                });

                // Keep recent events bounded
                if state.recent_events.len() > 500 {
                    state.recent_events.drain(0..250);
                }
            }
        }
    });

    WatcherHandle {
        state,
        command_tx: cmd_tx,
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
