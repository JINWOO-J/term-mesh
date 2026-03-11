import SwiftUI

/// Lightweight progress state for the titlebar progress bar.
struct TitlebarProgress {
    var value: Double      // 0.0–1.0, negative = indeterminate
    var label: String
    var color: Color

    /// Indeterminate progress (animated shimmer)
    var isIndeterminate: Bool { value < 0 }

    static func indeterminate(_ label: String, color: Color = .accentColor) -> TitlebarProgress {
        TitlebarProgress(value: -1, label: label, color: color)
    }
    static func determinate(_ value: Double, label: String, color: Color = .accentColor) -> TitlebarProgress {
        TitlebarProgress(value: min(1, max(0, value)), label: label, color: color)
    }
}

/// A 2px-tall progress bar displayed at the bottom edge of the titlebar.
/// Supports both determinate (0.0–1.0) and indeterminate (shimmer) modes.
struct TitlebarProgressBar: View {
    let progress: TitlebarProgress

    @State private var shimmerOffset: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                Rectangle()
                    .fill(progress.color.opacity(0.15))

                if progress.isIndeterminate {
                    // Animated shimmer bar
                    Rectangle()
                        .fill(progress.color.opacity(0.7))
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: shimmerOffset * geo.size.width)
                        .onAppear {
                            withAnimation(
                                .linear(duration: 1.2)
                                .repeatForever(autoreverses: false)
                            ) {
                                shimmerOffset = 1.0
                            }
                        }
                        .onDisappear {
                            shimmerOffset = -0.3
                        }
                } else {
                    // Determinate fill
                    Rectangle()
                        .fill(progress.color.opacity(0.8))
                        .frame(width: geo.size.width * progress.value)
                        .animation(.easeInOut(duration: 0.25), value: progress.value)
                }
            }
        }
        .frame(height: 2)
        .clipped()
    }
}
