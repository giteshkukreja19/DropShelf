import SwiftUI
import AppKit

enum ShelfSettingsPalette {
    static var accent: Color { .accentColor }
    static func content(_ scheme: ColorScheme) -> Material { .thick }
    static func window(_ scheme: ColorScheme) -> Color { Color(nsColor: .windowBackgroundColor) }
    static func card(_ scheme: ColorScheme) -> Color { Color.primary.opacity(scheme == .dark ? 0.045 : 0.035) }
}
