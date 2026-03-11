import Foundation

// MARK: - NotificationService Protocol

/// Abstracts the public API of TerminalNotificationStore for testability and loose coupling.
@MainActor
protocol NotificationService: AnyObject {
    var notifications: [TerminalNotification] { get }
    var unreadCount: Int { get }

    func unreadCount(forTabId tabId: UUID) -> Int
    func hasUnreadNotification(forTabId tabId: UUID, surfaceId: UUID?) -> Bool
    func latestNotification(forTabId tabId: UUID) -> TerminalNotification?

    func addNotification(tabId: UUID, surfaceId: UUID?, title: String, subtitle: String, body: String)
    func markRead(id: UUID)
    func markRead(forTabId tabId: UUID)
    func markRead(forTabId tabId: UUID, surfaceId: UUID?)
    func markUnread(forTabId tabId: UUID)
    func markAllRead()
    func remove(id: UUID)
    func clearAll()
    func clearNotifications(forTabId tabId: UUID, surfaceId: UUID?)
    func clearNotifications(forTabId tabId: UUID)
}

extension TerminalNotificationStore: NotificationService {}
