import SwiftUI

/// Full-width rainbow gradient banner shown briefly when a keyword is detected.
struct RainbowBannerView: View {
    let keyword: String

    private let rainbowColors: [Color] = [
        .red, .orange, .yellow, .green, .cyan, .blue, .purple
    ]

    var body: some View {
        Text("✨ \(keyword) ✨")
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 1)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: rainbowColors,
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
    }
}
