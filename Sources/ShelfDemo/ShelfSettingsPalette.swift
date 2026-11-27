import SwiftUI
import AppKit

enum ShelfSettingsPalette {
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }
    static var accent: Color { rgb(0, 122, 255) }
    static func content(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(35, 41, 44) : Color(nsColor: .windowBackgroundColor)
    }
    static func window(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(33, 39, 41) : Color(nsColor: .windowBackgroundColor)
    }
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(42, 47, 50) : Color(nsColor: .controlBackgroundColor)
    }
}
