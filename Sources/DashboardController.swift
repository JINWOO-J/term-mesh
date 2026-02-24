import AppKit
import WebKit

/// Manages the term-mesh monitoring dashboard in a separate window.
///
/// Watch criteria: each terminal tab's **project root** (detected by .git, Cargo.toml, etc.)
/// is watched for file events. This maps 1:1 with the blue grouped sessions in the sidebar.
@MainActor
final class DashboardController: NSObject, WKNavigationDelegate {
    static let shared = DashboardController()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var uiTimer: Timer?
    private var trackingTimer: Timer?
    private var trackedPIDs: Set<Int32> = []

    /// Project roots currently being watched — keyed by tab ID to avoid duplicates.
    private var watchedProjects: [UUID: String] = [:]

    /// Reference to the tab manager (set from AppDelegate.configure)
    weak var tabManager: TabManager? {
        didSet { startTracking() }
    }

    // MARK: - Always-On Tracking

    /// Start background tracking — runs always, regardless of dashboard window.
    func startTracking() {
        guard trackingTimer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.syncTrackingState()
        }
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.syncTrackingState()
        }
    }

    // MARK: - Dashboard Window

    func showDashboard() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        self.webView = wv

        if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html", inDirectory: "dashboard") {
            let htmlURL = URL(fileURLWithPath: htmlPath)
            wv.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else {
            let devPath = "/Users/jinwoo/work/cmux-term-mesh/Resources/dashboard/index.html"
            if FileManager.default.fileExists(atPath: devPath) {
                let url = URL(fileURLWithPath: devPath)
                wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "term-mesh Dashboard"
        win.contentView = wv
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        win.delegate = self
        self.window = win

        startUIPolling()
    }

    func closeDashboard() {
        stopUIPolling()
        window?.close()
        window = nil
        webView = nil
    }

    // MARK: - UI Polling (only when dashboard window is open)

    private func startUIPolling() {
        stopUIPolling()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.fetchAndPush()
        }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fetchAndPush()
        }
    }

    private func stopUIPolling() {
        uiTimer?.invalidate()
        uiTimer = nil
    }

    // MARK: - Tracking (always-on)

    private func syncTrackingState() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.discoverAndTrackDescendants()
            DispatchQueue.main.async {
                self?.watchTabProjects()
                self?.syncSessionsToDaemon()
            }
        }
    }

    /// Push current session list to daemon so HTTP dashboard can show the session picker.
    /// All tabs are synced regardless of watch safety — this is metadata for the session picker.
    private func syncSessionsToDaemon() {
        guard let tabManager else { return }

        var sessions: [[String: Any]] = []
        for workspace in tabManager.tabs {
            let cwd = workspace.currentDirectory
            guard !cwd.isEmpty else { continue }

            let projectRoot = findProjectRoot(from: cwd) ?? cwd

            var session: [String: Any] = [
                "id": workspace.id.uuidString,
                "name": workspace.title,
                "project_path": projectRoot,
            ]
            if let branch = workspace.gitBranch?.branch {
                session["git_branch"] = branch
            }
            sessions.append(session)
        }

        DispatchQueue.global(qos: .utility).async {
            TermMeshDaemon.shared.syncSessions(sessions)
        }
    }

    // MARK: - Process Discovery

    private func discoverAndTrackDescendants() {
        let appPID = ProcessInfo.processInfo.processIdentifier

        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-eo", "pid,ppid"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }

        var children: [Int32: [Int32]] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            children[ppid, default: []].append(pid)
        }

        var queue: [Int32] = children[appPID] ?? []
        var allDescendants: Set<Int32> = []
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard !allDescendants.contains(pid) else { continue }
            allDescendants.insert(pid)
            if let grandchildren = children[pid] {
                queue.append(contentsOf: grandchildren)
            }
        }

        let daemon = TermMeshDaemon.shared
        for pid in allDescendants {
            if !trackedPIDs.contains(pid) {
                daemon.trackPID(pid)
                DispatchQueue.main.async { [weak self] in
                    self?.trackedPIDs.insert(pid)
                }
            }
        }

        let deadPIDs = trackedPIDs.subtracting(allDescendants)
        for pid in deadPIDs {
            daemon.untrackPID(pid)
            DispatchQueue.main.async { [weak self] in
                self?.trackedPIDs.remove(pid)
            }
        }
    }

    // MARK: - Project Watch (per terminal tab)

    /// Watch the **project root** of each terminal tab's working directory.
    /// Each tab = one watched project. If a tab's directory changes, the watch updates.
    private func watchTabProjects() {
        guard let tabManager else { return }

        var currentTabProjects: [UUID: String] = [:]

        for workspace in tabManager.tabs {
            let cwd = workspace.currentDirectory
            guard !cwd.isEmpty else { continue }

            // Find the project root from the tab's current directory
            let projectRoot = findProjectRoot(from: cwd) ?? cwd

            // Skip dangerous/broad paths
            guard isSafeToWatch(projectRoot) else { continue }

            currentTabProjects[workspace.id] = projectRoot
        }

        let daemon = TermMeshDaemon.shared

        // Watch new projects
        for (tabId, projectRoot) in currentTabProjects {
            if watchedProjects[tabId] != projectRoot {
                // If this tab was watching a different path, unwatch the old one
                if let oldPath = watchedProjects[tabId] {
                    // Only unwatch if no other tab is watching the same path
                    let otherTabsWatchingSame = watchedProjects
                        .filter { $0.key != tabId && $0.value == oldPath }
                        .count > 0
                    if !otherTabsWatchingSame {
                        DispatchQueue.global(qos: .utility).async {
                            daemon.unwatchPath(oldPath)
                        }
                    }
                }
                watchedProjects[tabId] = projectRoot
                DispatchQueue.global(qos: .utility).async {
                    daemon.watchPath(projectRoot)
                }
            }
        }

        // Unwatch closed tabs
        let closedTabIds = Set(watchedProjects.keys).subtracting(Set(currentTabProjects.keys))
        for tabId in closedTabIds {
            if let oldPath = watchedProjects.removeValue(forKey: tabId) {
                let otherTabsWatchingSame = watchedProjects.values.contains(oldPath)
                if !otherTabsWatchingSame {
                    DispatchQueue.global(qos: .utility).async {
                        daemon.unwatchPath(oldPath)
                    }
                }
            }
        }
    }

    /// Walk up from `directory` looking for project markers (.git, Cargo.toml, etc.)
    private func findProjectRoot(from directory: String) -> String? {
        let markers = [".git", "Package.swift", "Cargo.toml", "package.json", "go.mod",
                       "pyproject.toml", "Makefile", ".xcodeproj"]
        var current = directory
        let fm = FileManager.default

        while current != "/" && current != "" {
            for marker in markers {
                let path = (current as NSString).appendingPathComponent(marker)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir) {
                    return current
                }
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Reject paths that are too broad to watch recursively.
    private func isSafeToWatch(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dangerous = ["/", "/Users", "/tmp", "/var", "/private", home]
        return !dangerous.contains(path)
    }

    // MARK: - Data Push (WKWebView only)

    private func fetchAndPush() {
        guard let webView else { return }

        DispatchQueue.global(qos: .utility).async {
            let daemon = TermMeshDaemon.shared
            let monitorData = daemon.rpcCallRaw(method: "monitor.snapshot", params: [:])
            let watcherData = daemon.rpcCallRaw(method: "watcher.snapshot", params: [:])

            DispatchQueue.main.async {
                if let json = monitorData {
                    webView.evaluateJavaScript("updateMonitor(\(json));") { _, error in
                        if let error { print("[dashboard] monitor error: \(error)") }
                    }
                }
                if let json = watcherData {
                    webView.evaluateJavaScript("updateHeatmap(\(json));") { _, error in
                        if let error { print("[dashboard] heatmap error: \(error)") }
                    }
                }
            }
        }
    }
}

// MARK: - NSWindowDelegate

extension DashboardController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            stopUIPolling()
            webView = nil
            window = nil
        }
    }
}
