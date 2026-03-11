import Foundation

// MARK: - BrowserHistoryService Protocol

/// Abstracts the public API of BrowserHistoryStore for testability and loose coupling.
protocol BrowserHistoryService: AnyObject {
    var entries: [BrowserHistoryStore.Entry] { get }

    func loadIfNeeded()
    func recordVisit(url: URL?, title: String?)
    func recordTypedNavigation(url: URL?)
    func suggestions(for input: String, limit: Int) -> [BrowserHistoryStore.Entry]
    func recentSuggestions(limit: Int) -> [BrowserHistoryStore.Entry]
}

extension BrowserHistoryStore: BrowserHistoryService {}
