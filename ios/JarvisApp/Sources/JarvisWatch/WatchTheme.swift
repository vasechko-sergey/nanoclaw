import SwiftUI

/// Minimal theme constants for the watchOS app. Mirrors the colour palette
/// from the iOS Theme but uses fixed font sizes — no UIScreen-based scaling
/// (watch screens are too small + UIScreen behaves differently here).
enum WatchTheme {
    static let background = Color(red: 0.04, green: 0.055, blue: 0.08)
    static let surface    = Color(red: 0.067, green: 0.098, blue: 0.133)
    static let accent     = Color(red: 0.33, green: 0.74, blue: 0.77)
    static let accentMed  = Color(red: 0.258, green: 0.569, blue: 0.598)
    static let online     = Color(red: 0.29, green: 0.87, blue: 0.50)
    static let offline    = Color(red: 0.95, green: 0.26, blue: 0.21)
    static let textPrimary = Color.white
    static let textTertiary = Color(red: 0.568, green: 0.575, blue: 0.586)

    static let messageFont = Font.system(size: 13, design: .default)
    static let metaFont    = Font.system(size: 10, design: .monospaced)
}
