import SwiftUI

/// Singleton store for driving the rainbow banner overlay.
/// Call `trigger(keyword:)` from any thread — it dispatches to MainActor.
@MainActor
final class RainbowBannerStore: ObservableObject {
    static let shared = RainbowBannerStore()

    @Published private(set) var isVisible = false
    @Published private(set) var keyword = ""

    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// Show the banner with the detected keyword, then auto-dismiss after 2.5 s.
    func trigger(keyword: String) {
        self.keyword = keyword
        dismissTask?.cancel()
        withAnimation(.easeIn(duration: 0.2)) {
            isVisible = true
        }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) {
                self.isVisible = false
            }
        }
    }
}
