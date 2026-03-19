import Foundation

// MARK: - Settings

enum IMEInputBarSettings {
    static let defaultFontSize: Double = 12
    static let defaultHeight: Double = 90

    static var fontSize: CGFloat {
        let val = UserDefaults.standard.double(forKey: "imeBarFontSize")
        return val > 0 ? CGFloat(val) : CGFloat(defaultFontSize)
    }

    static var height: CGFloat {
        let val = UserDefaults.standard.double(forKey: "imeBarHeight")
        return val > 0 ? CGFloat(val) : CGFloat(defaultHeight)
    }
}

// MARK: - History persistence

enum IMEHistory {
    static let key = "imeInputBarHistory"
    static let maxEntries = 30

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ entries: [String]) {
        UserDefaults.standard.set(Array(entries.prefix(maxEntries)), forKey: key)
    }

    /// Merged history: IME own entries → Claude prompt history → shell history (deduplicated).
    /// All sources are always included so the user can access any previous input regardless
    /// of what is currently running in the terminal.
    static func loadMerged() -> [String] {
        let imeEntries = load()
        let claudeEntries = ClaudeHistory.load()
        let shellEntries = ShellHistory.load()
        var seen = Set<String>()
        var merged: [String] = []
        for entry in imeEntries + claudeEntries + shellEntries {
            if !seen.contains(entry) {
                seen.insert(entry)
                merged.append(entry)
            }
        }
        return Array(merged.prefix(200))
    }
}

// MARK: - Claude Code history reader

enum ClaudeHistory {
    /// Reads `~/.claude/history.jsonl` and returns prompt display strings,
    /// most recent first. Entries are capped to avoid memory bloat.
    static func load() -> [String] {
        let historyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/history.jsonl")
        guard let data = try? Data(contentsOf: historyPath),
              let content = String(data: data, encoding: .utf8) else { return [] }

        let lines = content.components(separatedBy: .newlines)
        var entries: [String] = []
        entries.reserveCapacity(min(lines.count, 300))

        // Parse in reverse (most recent last in file → most recent first in result)
        for line in lines.reversed() {
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let display = obj["display"] as? String else { continue }

            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empty, slash commands, and very short entries
            if trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed.count < 2 { continue }
            // Cap individual entry length
            let capped = trimmed.count > 1000 ? String(trimmed.prefix(1000)) : trimmed
            entries.append(capped)
            if entries.count >= 300 { break }
        }
        return entries
    }
}

// MARK: - Shell history reader

enum ShellHistory {
    /// Reads shell history (~/.zsh_history or ~/.bash_history), most recent first.
    static func load() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Try zsh first, then bash
        let candidates = [
            home.appendingPathComponent(".zsh_history"),
            home.appendingPathComponent(".bash_history"),
        ]
        guard let historyURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: historyURL),
              let content = String(data: data, encoding: .utf8) else { return [] }

        let isZsh = historyURL.lastPathComponent == ".zsh_history"
        let lines = content.components(separatedBy: .newlines)
        var entries: [String] = []
        entries.reserveCapacity(min(lines.count, 300))

        // Parse in reverse (most recent at the end of file)
        for line in lines.reversed() {
            guard !line.isEmpty else { continue }
            let command: String
            if isZsh, line.hasPrefix(": ") {
                // Extended zsh format: ": timestamp:0;command"
                if let semicolonIdx = line.firstIndex(of: ";") {
                    command = String(line[line.index(after: semicolonIdx)...])
                } else {
                    continue
                }
            } else {
                command = line
            }
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.count < 2 { continue }
            // Skip duplicates within shell history
            if entries.contains(trimmed) { continue }
            let capped = trimmed.count > 1000 ? String(trimmed.prefix(1000)) : trimmed
            entries.append(capped)
            if entries.count >= 300 { break }
        }
        return entries
    }
}

// MARK: - Claude Code slash commands

enum SlashCommands {
    /// Built-in Claude Code slash commands (from v2.1.72)
    static let builtinCommands: [String] = [
        "/add-dir", "/agents", "/btw", "/chrome", "/clear", "/color", "/compact",
        "/config", "/context", "/copy", "/cost", "/desktop", "/diff", "/doctor",
        "/effort", "/exit", "/export", "/extra-usage", "/fast", "/feedback",
        "/branch", "/help", "/hooks", "/ide", "/init", "/insights",
        "/install-github-app", "/install-slack-app", "/keybindings",
        "/login", "/logout", "/mcp", "/memory", "/mobile", "/model", "/passes",
        "/permissions", "/plan", "/plugin", "/pr-comments", "/privacy-settings",
        "/release-notes", "/reload-plugins", "/remote-control", "/remote-env",
        "/rename", "/resume", "/review", "/rewind", "/sandbox", "/security-review",
        "/skills", "/stats", "/status", "/statusline", "/stickers", "/tasks",
        "/terminal-setup", "/theme", "/upgrade", "/usage", "/vim", "/voice",
        // Common aliases
        "/quit", "/reset", "/new", "/settings", "/app", "/bug", "/fork",
        "/continue", "/checkpoint", "/allowed-tools", "/rc", "/ios", "/android",
        // Bundled skills
        "/batch", "/claude-api", "/debug", "/loop", "/simplify",
    ]

    /// Loads built-in commands merged with custom commands from .claude/commands/ directories.
    static func loadAll() -> [String] {
        var commands = builtinCommands
        // Project-local commands
        let projectDir = FileManager.default.currentDirectoryPath + "/.claude/commands"
        commands += scanCommandDir(projectDir)
        // User global commands
        let userDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/commands").path
        commands += scanCommandDir(userDir)
        // Dedupe and sort
        return Array(Set(commands)).sorted()
    }

    private static func scanCommandDir(_ path: String) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return files.compactMap { file -> String? in
            guard file.hasSuffix(".md") else { return nil }
            return "/" + file.replacingOccurrences(of: ".md", with: "")
        }
    }
}
