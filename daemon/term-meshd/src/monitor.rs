use serde::Serialize;
use std::collections::{HashMap, HashSet};
use sysinfo::{Pid, ProcessesToUpdate, System};
use tokio::sync::watch;
use tokio::time::{interval, Duration};

/// Snapshot of a single process's resource usage.
#[derive(Debug, Clone, Serialize)]
pub struct ProcessSnapshot {
    pub pid: u32,
    pub name: String,
    pub cpu_percent: f32,
    pub memory_bytes: u64,
}

/// System-wide resource snapshot.
#[derive(Debug, Clone, Serialize)]
pub struct SystemSnapshot {
    pub timestamp_ms: u64,
    pub total_memory_bytes: u64,
    pub used_memory_bytes: u64,
    pub cpu_count: usize,
    /// Per-process stats for tracked PIDs
    pub processes: Vec<ProcessSnapshot>,
    /// Budget guard alerts
    pub alerts: Vec<BudgetAlert>,
}

#[derive(Debug, Clone, Serialize)]
pub struct BudgetAlert {
    pub pid: u32,
    pub kind: String, // "cpu" | "memory"
    pub value: f64,
    pub threshold: f64,
}

#[derive(Debug, Clone)]
pub struct BudgetConfig {
    pub cpu_threshold_percent: f32,
    pub memory_threshold_bytes: u64,
}

impl Default for BudgetConfig {
    fn default() -> Self {
        Self {
            cpu_threshold_percent: 90.0,
            memory_threshold_bytes: 4 * 1024 * 1024 * 1024, // 4 GB
        }
    }
}

/// Detect the daemon's parent PID (typically the Swift app).
fn detect_root_pid(sys: &mut System) -> Option<u32> {
    let my_pid = std::process::id();
    sys.refresh_processes(ProcessesToUpdate::Some(&[Pid::from_u32(my_pid)]), true);
    let parent = sys
        .process(Pid::from_u32(my_pid))
        .and_then(|p| p.parent())
        .map(|p| p.as_u32());
    if let Some(ppid) = parent {
        tracing::info!("auto-discovery root PID: {ppid} (daemon parent)");
    }
    parent
}

/// BFS to find all descendant PIDs of root_pid.
fn find_descendants(sys: &System, root_pid: u32) -> HashSet<u32> {
    let mut children_map: HashMap<u32, Vec<u32>> = HashMap::new();
    for (&pid, proc_info) in sys.processes() {
        if let Some(ppid) = proc_info.parent() {
            children_map
                .entry(ppid.as_u32())
                .or_default()
                .push(pid.as_u32());
        }
    }

    let mut result = HashSet::new();
    let mut queue: Vec<u32> = children_map.get(&root_pid).cloned().unwrap_or_default();
    while let Some(pid) = queue.pop() {
        if result.insert(pid) {
            if let Some(kids) = children_map.get(&pid) {
                queue.extend(kids);
            }
        }
    }
    result
}

/// Start background resource monitor with auto-process-discovery.
/// Watch paths are managed separately by the Swift app (per terminal tab).
pub fn start_monitor(
    config: BudgetConfig,
) -> (watch::Receiver<Option<SystemSnapshot>>, MonitorHandle) {
    let (tx, rx) = watch::channel(None);
    let handle = MonitorHandle {
        tracked_pids: std::sync::Arc::new(std::sync::Mutex::new(Vec::new())),
    };
    let pids = handle.tracked_pids.clone();
    let daemon_pid = std::process::id();

    tokio::spawn(async move {
        let mut sys = System::new_all();
        let mut tick = interval(Duration::from_secs(2));

        // Detect root PID (parent of daemon = Swift app)
        let root_pid = detect_root_pid(&mut sys);

        loop {
            tick.tick().await;
            sys.refresh_memory();
            sys.refresh_cpu_usage();

            // Refresh ALL processes for auto-discovery
            sys.refresh_processes(ProcessesToUpdate::All, true);

            // Auto-discover descendants of root PID
            if let Some(root) = root_pid {
                let descendants = find_descendants(&sys, root);
                let mut tracked = pids.lock().unwrap();

                for &pid in &descendants {
                    if pid != daemon_pid && !tracked.contains(&pid) {
                        tracked.push(pid);
                        tracing::debug!("auto-tracked PID {pid}");
                    }
                }

                // Remove dead PIDs
                tracked.retain(|&pid| sys.process(Pid::from_u32(pid)).is_some());
            }

            let tracked: Vec<u32> = pids.lock().unwrap().clone();

            let mut processes = Vec::new();
            let mut alerts = Vec::new();

            for &pid in &tracked {
                if let Some(proc) = sys.process(Pid::from_u32(pid)) {
                    let cpu = proc.cpu_usage();
                    let mem = proc.memory();
                    processes.push(ProcessSnapshot {
                        pid,
                        name: proc.name().to_string_lossy().into_owned(),
                        cpu_percent: cpu,
                        memory_bytes: mem,
                    });

                    if cpu > config.cpu_threshold_percent {
                        alerts.push(BudgetAlert {
                            pid,
                            kind: "cpu".into(),
                            value: cpu as f64,
                            threshold: config.cpu_threshold_percent as f64,
                        });
                    }
                    if mem > config.memory_threshold_bytes {
                        alerts.push(BudgetAlert {
                            pid,
                            kind: "memory".into(),
                            value: mem as f64,
                            threshold: config.memory_threshold_bytes as f64,
                        });
                    }
                }
            }

            let snapshot = SystemSnapshot {
                timestamp_ms: std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as u64,
                total_memory_bytes: sys.total_memory(),
                used_memory_bytes: sys.used_memory(),
                cpu_count: sys.cpus().len(),
                processes,
                alerts,
            };

            let _ = tx.send(Some(snapshot));
        }
    });

    (rx, handle)
}

/// Handle to add/remove tracked PIDs.
#[derive(Clone)]
pub struct MonitorHandle {
    tracked_pids: std::sync::Arc<std::sync::Mutex<Vec<u32>>>,
}

impl MonitorHandle {
    pub fn track_pid(&self, pid: u32) {
        let mut pids = self.tracked_pids.lock().unwrap();
        if !pids.contains(&pid) {
            pids.push(pid);
            tracing::info!("tracking PID {pid}");
        }
    }

    pub fn untrack_pid(&self, pid: u32) {
        let mut pids = self.tracked_pids.lock().unwrap();
        pids.retain(|&p| p != pid);
        tracing::info!("untracked PID {pid}");
    }

    pub fn tracked_pids(&self) -> Vec<u32> {
        self.tracked_pids.lock().unwrap().clone()
    }
}
