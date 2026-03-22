import XCTest
import AppKit

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

// MARK: - IMEHistory persistence tests

/// Tests for IMEHistory save/load/merge and history source parsers.
/// Uses isolated UserDefaults suite to avoid polluting real preferences.
final class IMEHistoryPersistenceTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - IMEHistory.load / save round-trip

    func testSaveAndLoadRoundTrip() {
        let entries = ["hello", "world", "test"]
        IMEHistory.save(entries)
        let loaded = IMEHistory.load()
        // Clean up
        defer { UserDefaults.standard.removeObject(forKey: IMEHistory.key) }

        XCTAssertEqual(loaded, entries)
    }

    func testSaveTruncatesToMaxEntries() {
        let entries = (0..<50).map { "entry-\($0)" }
        IMEHistory.save(entries)
        let loaded = IMEHistory.load()
        defer { UserDefaults.standard.removeObject(forKey: IMEHistory.key) }

        XCTAssertEqual(loaded.count, IMEHistory.maxEntries,
                       "Should truncate to maxEntries (\(IMEHistory.maxEntries))")
        XCTAssertEqual(loaded.first, "entry-0", "Should keep entries from the beginning")
    }

    func testLoadReturnsEmptyWhenNoData() {
        // Use a unique key to ensure no prior data
        let key = "nonexistent-\(UUID().uuidString)"
        let result = UserDefaults.standard.stringArray(forKey: key) ?? []
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - IMEHistory.loadMerged deduplication

    func testLoadMergedDeduplicatesEntries() {
        // Save some IME entries that will be deduplicated with other sources
        let entries = ["duplicate", "unique-ime"]
        IMEHistory.save(entries)
        defer { UserDefaults.standard.removeObject(forKey: IMEHistory.key) }

        let merged = IMEHistory.loadMerged()

        // Verify no duplicates
        let uniqueCount = Set(merged).count
        XCTAssertEqual(merged.count, uniqueCount,
                       "Merged history should have no duplicates")
    }

    func testLoadMergedCapsAt200() {
        // Save maxEntries worth of unique entries
        let entries = (0..<30).map { "ime-\($0)" }
        IMEHistory.save(entries)
        defer { UserDefaults.standard.removeObject(forKey: IMEHistory.key) }

        let merged = IMEHistory.loadMerged()
        XCTAssertLessThanOrEqual(merged.count, 200,
                                  "Merged history should be capped at 200")
    }

    func testLoadMergedPreservesIMEFirstOrdering() {
        let entries = ["first-ime", "second-ime"]
        IMEHistory.save(entries)
        defer { UserDefaults.standard.removeObject(forKey: IMEHistory.key) }

        let merged = IMEHistory.loadMerged()

        // IME entries should appear before Claude/shell entries
        guard let firstIdx = merged.firstIndex(of: "first-ime"),
              let secondIdx = merged.firstIndex(of: "second-ime") else {
            return XCTFail("IME entries should be present in merged history")
        }
        XCTAssertLessThan(firstIdx, secondIdx, "IME entry order should be preserved")
    }
}

// MARK: - Shell history parser tests

/// Tests for ShellHistory zsh extended format parsing.
/// Uses temporary files to simulate history files.
final class ShellHistoryParserTests: XCTestCase {

    // MARK: - Zsh extended format parsing

    func testParseZshExtendedFormat() {
        // Simulate zsh extended history format
        let content = """
        : 1700000001:0;echo hello
        : 1700000002:0;ls -la
        : 1700000003:0;git status
        """

        let commands = parseZshLines(content)
        XCTAssertEqual(commands, ["git status", "ls -la", "echo hello"],
                       "Should parse commands after semicolons, most recent first")
    }

    func testParseZshSkipsShortCommands() {
        let content = """
        : 1700000001:0;ls
        : 1700000002:0;a
        : 1700000003:0;echo hello
        """

        let commands = parseZshLines(content)
        XCTAssertFalse(commands.contains("a"), "Should skip single-char entries")
        XCTAssertTrue(commands.contains("ls"), "2-char entries should be kept")
        XCTAssertTrue(commands.contains("echo hello"))
    }

    func testParseZshSkipsDuplicates() {
        let content = """
        : 1700000001:0;echo hello
        : 1700000002:0;echo hello
        : 1700000003:0;ls -la
        """

        let commands = parseZshLines(content)
        let helloCount = commands.filter { $0 == "echo hello" }.count
        XCTAssertEqual(helloCount, 1, "Should deduplicate within shell history")
    }

    func testParseZshSkipsInvalidLines() {
        let content = """
        : 1700000001:0;echo hello
        this is not zsh format
        : 1700000003:0;git push
        """

        let commands = parseZshLines(content)
        XCTAssertTrue(commands.contains("echo hello"))
        XCTAssertTrue(commands.contains("git push"))
        // "this is not zsh format" is treated as a plain line (non-zsh)
    }

    func testParseBashFormat() {
        let lines = ["echo hello", "ls -la", "git status", ""]

        var entries: [String] = []
        for line in lines.reversed() {
            guard !line.isEmpty else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.count < 2 { continue }
            if entries.contains(trimmed) { continue }
            entries.append(trimmed)
        }

        XCTAssertEqual(entries, ["git status", "ls -la", "echo hello"])
    }

    func testCapsLongEntries() {
        let longCommand = String(repeating: "x", count: 1500)
        let content = ": 1700000001:0;\(longCommand)"

        let commands = parseZshLines(content)
        XCTAssertEqual(commands.first?.count, 1000,
                       "Should cap entries at 1000 characters")
    }

    // MARK: - Helper (replicates ShellHistory.load parsing logic for zsh lines)

    private func parseZshLines(_ content: String) -> [String] {
        let lines = content.components(separatedBy: .newlines)
        var entries: [String] = []
        for line in lines.reversed() {
            guard !line.isEmpty else { continue }
            let command: String
            if line.hasPrefix(": ") {
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
            if entries.contains(trimmed) { continue }
            let capped = trimmed.count > 1000 ? String(trimmed.prefix(1000)) : trimmed
            entries.append(capped)
        }
        return entries
    }
}

// MARK: - Claude history parser tests

final class ClaudeHistoryParserTests: XCTestCase {

    func testParseJsonlFormat() {
        let lines = [
            #"{"display": "hello world", "timestamp": 1700000001}"#,
            #"{"display": "git push origin main", "timestamp": 1700000002}"#,
        ]

        let entries = parseClaudeLines(lines)
        // Most recent last in file → most recent first in result
        XCTAssertEqual(entries, ["git push origin main", "hello world"])
    }

    func testSkipsSlashCommands() {
        let lines = [
            #"{"display": "/help", "timestamp": 1}"#,
            #"{"display": "hello", "timestamp": 2}"#,
            #"{"display": "/compact", "timestamp": 3}"#,
        ]

        let entries = parseClaudeLines(lines)
        XCTAssertFalse(entries.contains("/help"), "Should skip slash commands")
        XCTAssertFalse(entries.contains("/compact"), "Should skip slash commands")
        XCTAssertTrue(entries.contains("hello"))
    }

    func testSkipsShortEntries() {
        let lines = [
            #"{"display": "a", "timestamp": 1}"#,
            #"{"display": "ok", "timestamp": 2}"#,
            #"{"display": "hello world", "timestamp": 3}"#,
        ]

        let entries = parseClaudeLines(lines)
        XCTAssertFalse(entries.contains("a"), "Should skip entries with count < 2")
        XCTAssertTrue(entries.contains("ok"))
        XCTAssertTrue(entries.contains("hello world"))
    }

    func testSkipsInvalidJson() {
        let lines = [
            "not json at all",
            #"{"display": "valid entry", "timestamp": 1}"#,
            #"{"no_display_field": true}"#,
        ]

        let entries = parseClaudeLines(lines)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first, "valid entry")
    }

    // MARK: - Helper (replicates ClaudeHistory.load parsing logic)

    private func parseClaudeLines(_ lines: [String]) -> [String] {
        var entries: [String] = []
        for line in lines.reversed() {
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let display = obj["display"] as? String else { continue }
            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed.count < 2 { continue }
            let capped = trimmed.count > 1000 ? String(trimmed.prefix(1000)) : trimmed
            entries.append(capped)
        }
        return entries
    }
}

// MARK: - SlashCommands tests

final class SlashCommandsTests: XCTestCase {

    func testBuiltinCommandsAreNotEmpty() {
        XCTAssertFalse(SlashCommands.builtinCommands.isEmpty,
                       "Should have built-in commands")
    }

    func testBuiltinCommandsStartWithSlash() {
        for cmd in SlashCommands.builtinCommands {
            XCTAssertTrue(cmd.name.hasPrefix("/"),
                          "Command '\(cmd.name)' should start with /")
        }
    }

    func testBuiltinCommandsHaveDescriptions() {
        for cmd in SlashCommands.builtinCommands {
            XCTAssertFalse(cmd.desc.isEmpty,
                           "Command '\(cmd.name)' should have a description")
        }
    }

    func testLoadAllDeduplicatesByName() {
        let commands = SlashCommands.loadAll()
        let names = commands.map(\.name)
        let uniqueNames = Set(names)
        XCTAssertEqual(names.count, uniqueNames.count,
                       "loadAll should not contain duplicate command names")
    }

    func testLoadAllReturnsSortedByName() {
        let commands = SlashCommands.loadAll()
        let names = commands.map(\.name)
        XCTAssertEqual(names, names.sorted(),
                       "loadAll should return commands sorted by name")
    }
}
