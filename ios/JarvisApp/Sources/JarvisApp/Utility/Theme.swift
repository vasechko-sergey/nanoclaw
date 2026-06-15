import SwiftUI
import UIKit

enum Theme {

    // MARK: – Adaptive scale
    // Base: 390pt (iPhone 13/14/15 Pro). Clamped so extremes stay sane.

    /// Cached scale factor. Refreshed lazily on first access and explicitly via
    /// `refreshScale()` when the host app sees a scene-phase change.
    private static var _cachedScale: CGFloat?

    /// Force a re-read of the active window scene width. Call from the app's
    /// scene observer when the active scene changes or rotates.
    static func refreshScale() {
        _cachedScale = computeScale()
    }

    /// Set the scale from an explicit available-area width (preferred — call
    /// from RootAdaptiveView's GeometryReader). Same clamp as computeScale().
    static func refreshScale(width: CGFloat) {
        _cachedScale = min(max(width / 390, 0.92), 1.15)
    }

    private static func computeScale() -> CGFloat {
        let width = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .screen.bounds.width
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first?
                .screen.bounds.width
            ?? 390
        return min(max(width / 390, 0.92), 1.15)
    }

    /// 0.96 on 12 mini (375), 1.0 on 13 Pro (390), 1.01 on 16 Pro (393), 1.10 on Pro Max (430)
    static var scale: CGFloat {
        if let cached = _cachedScale { return cached }
        let s = computeScale()
        _cachedScale = s
        return s
    }
    /// Rounds a base value by current scale
    static func scaled(_ base: CGFloat) -> CGFloat { round(base * scale) }

    // MARK: – Backgrounds
    static let background    = Color(red: 0.04, green: 0.055, blue: 0.08)   // #0A0E14
    static let surface       = Color(red: 0.067, green: 0.098, blue: 0.133) // #111922
    static let surfaceBorder = Color.white.opacity(0.08)

    // MARK: – Accent palette (WCAG AA verified)
    /// Primary interactive — buttons, links, active states. 8.7:1 on bg.
    static let accent       = Color(red: 0.33, green: 0.74, blue: 0.77)     // #54BEC4
    /// Icons, timestamps, section headers, secondary interactive. 5.3:1 on bg, 4.8:1 on surface.
    static let accentMedium = Color(red: 0.258, green: 0.569, blue: 0.598)  // #429199
    /// Decorative only — large text labels, borders. 3.8:1 on bg (large text OK).
    static let accentSubtle = Color(red: 0.214, green: 0.466, blue: 0.494)  // #37777E

    // MARK: – Status
    static let online  = Color(red: 0.29, green: 0.87, blue: 0.50)  // #4ADE80
    static let offline = Color(red: 0.95, green: 0.26, blue: 0.21)  // #F24236, 5.0:1 on bg

    // MARK: – Text (WCAG AA verified)
    static let textPrimary   = Color.white                                    // 19.3:1 on bg
    static let textSecondary = Color.white.opacity(0.7)                       //  9.2:1 on bg
    /// Replaces old textDim. Previews, captions, muted content. 6.2:1 on bg, 5.7:1 on surface.
    static let textTertiary  = Color(red: 0.568, green: 0.575, blue: 0.586)  // #919397
    /// Timestamps — accent-tinted, guaranteed 5.3:1. Alias for accentMedium.
    static let timestamp     = accentMedium

    // MARK: – Font sizes (adaptive)
    static var fontBody:      CGFloat { max(scaled(16), 15) }     // message text
    static var fontCaption:   CGFloat { max(scaled(13), 12) }     // timestamps, labels
    static var fontSmall:     CGFloat { max(scaled(12), 11) }     // section headers
    static var fontTitle:     CGFloat { max(scaled(13), 12) }     // header «J A R V I S»
    static var fontChip:      CGFloat { max(scaled(14), 13) }     // suggestion chips
    static var fontInput:     CGFloat { 16 }                      // always 16 — prevents iOS zoom
    static var fontSubhead:   CGFloat { max(scaled(15), 14) }     // list items, buttons

    // MARK: – Typography
    static var titleTracking: CGFloat { scaled(4) }
    static var titleFont: Font { .system(size: fontTitle, weight: .light) }

    // MARK: – Corners (adaptive)
    static var inputRadius:  CGFloat { scaled(20) }
    static var chipRadius:   CGFloat { scaled(14) }
    static var cardRadius:   CGFloat { scaled(12) }

    // MARK: – Spacing (adaptive)
    static var headerHeight: CGFloat { scaled(48) }
    static let minTapSize:   CGFloat = 44  // Apple HIG — fixed
    static var hPadding:     CGFloat { scaled(16) }    // standard horizontal padding
    static var messagePadH:  CGFloat { scaled(14) }    // bubble inner padding H
    static var messagePadV:  CGFloat { scaled(10) }    // bubble inner padding V
    static var orbSize:      CGFloat { scaled(120) }   // empty state orb

    // MARK: – Bubbleless row tokens (2026 redesign)
    static let rowPadV: CGFloat = 12
    static let rowPadH: CGFloat = 18
    static let metaFont = Font.system(size: 10, design: .monospaced)
    static let avatarDotSize: CGFloat = 8
    static let hairlineColor = Theme.accent.opacity(0.05)
    private static var _cachedDrawerWidth: CGFloat?

    static func refreshDrawerWidth() {
        _cachedDrawerWidth = computeDrawerWidth()
    }

    /// Set the drawer width from an explicit available-area width.
    static func refreshDrawerWidth(width: CGFloat) {
        _cachedDrawerWidth = width * 0.78
    }

    private static func computeDrawerWidth() -> CGFloat {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen
        return (screen?.bounds.width ?? 393) * 0.78
    }

    static var drawerWidth: CGFloat {
        if let cached = _cachedDrawerWidth { return cached }
        let v = computeDrawerWidth()
        _cachedDrawerWidth = v
        return v
    }
    static let inputBarRadius: CGFloat = 22

    // MARK: – Visual tokens (audit pass v2)

    // Corner radii — 3-tier scale (existing cardRadius=12, chipRadius=14, inputRadius=20 retained as legacy aliases)
    static let radiusSmall:  CGFloat = 8     // status banner, file card, chip
    static let radiusMedium: CGFloat = 12    // sheets, action cards
    static let radiusLarge:  CGFloat = 20    // input bar pill

    // Stroke widths
    static let lineHairline: CGFloat = 0.5   // borders on pills, rows, hairline separators
    static let lineAccent:   CGFloat = 1.5   // status indicators, emphasized strokes

    // Small-text font sizes
    static let fontXSmall: CGFloat = 10      // mono meta row, date separator
    static let fontTiny:   CGFloat = 11      // banner pulse, ticks

    // Reusable colors
    static let assistantText  = Color(red: 0.88, green: 0.94, blue: 0.95)  // body text on assistant rows
    static let inputBg        = Color.white.opacity(0.04)                  // input bar fill
    static let avatarUserDot  = Color.white.opacity(0.25)                  // bubbleless user avatar dot

    // Animation durations
    static let animFast:   Double = 0.2      // small UI transitions
    static let animMedium: Double = 0.35     // drawer, sheet, phase change
    static let animSlow:   Double = 0.5      // emphasis, splash hand-off

    // MARK: – Haptics
    static func hapticSend()    { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func hapticReceive() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func hapticMedium()  { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func hapticSuccess() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func hapticError()   { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
