import AppKit
import SwiftUI

struct GhosttyTheme {
    let backgroundColor: NSColor
    let backgroundOpacity: CGFloat
    let isLightBackground: Bool

    static let `default` = GhosttyTheme(
        backgroundColor: .black,
        backgroundOpacity: 1.0,
        isLightBackground: false
    )

    static var current: GhosttyTheme {
        let color = GhosttyApp.shared.defaultBackgroundColor
        let opacity = CGFloat(GhosttyApp.shared.defaultBackgroundOpacity)
        return GhosttyTheme(
            backgroundColor: color,
            backgroundOpacity: opacity,
            isLightBackground: color.isLightColor
        )
    }
}

struct GhosttyThemeKey: EnvironmentKey {
    static let defaultValue: GhosttyTheme = .default
}

extension EnvironmentValues {
    var ghosttyTheme: GhosttyTheme {
        get { self[GhosttyThemeKey.self] }
        set { self[GhosttyThemeKey.self] = newValue }
    }
}
