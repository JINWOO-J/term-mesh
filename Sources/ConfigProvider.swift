import AppKit
import SwiftUI

/// Protocol abstracting GhosttyApp's configuration API for testability and decoupling.
protocol GhosttyConfigProvider: AnyObject {
    var defaultBackgroundColor: NSColor { get }
    var defaultBackgroundOpacity: Double { get }
    var backgroundLogEnabled: Bool { get }
    var isScrolling: Bool { get }

    func reloadConfiguration(soft: Bool, source: String)
    func openConfigurationInTextEdit()
    func logBackground(_ message: String)
    func markScrollActivity(hasMomentum: Bool, momentumEnded: Bool)
}

extension GhosttyApp: GhosttyConfigProvider {}

extension GhosttyConfigProvider {
    func logBackgroundIfEnabled(_ message: @autoclosure () -> String) {
        guard backgroundLogEnabled else { return }
        logBackground(message())
    }

    func reloadConfiguration(source: String) {
        reloadConfiguration(soft: false, source: source)
    }
}

// MARK: - SwiftUI Environment

struct GhosttyConfigProviderKey: EnvironmentKey {
    static let defaultValue: (any GhosttyConfigProvider)? = nil
}

extension EnvironmentValues {
    var configProvider: (any GhosttyConfigProvider)? {
        get { self[GhosttyConfigProviderKey.self] }
        set { self[GhosttyConfigProviderKey.self] = newValue }
    }
}
