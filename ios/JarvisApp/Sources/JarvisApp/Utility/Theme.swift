import SwiftUI
import UIKit

enum Theme {

    // MARK: – Adaptive scale
    // Base: 390pt (iPhone 13/14/15 Pro). Clamped so extremes stay sane.
    private static var screenWidth: CGFloat { UIScreen.main.bounds.width }
    /// 0.96 on 12 mini (375), 1.0 on 13 Pro (390), 1.01 on 16 Pro (393), 1.10 on Pro Max (430)
    static var scale: CGFloat { min(max(screenWidth / 390, 0.92), 1.15) }
    /// Rounds a base value by current scale
    static func scaled(_ base: CGFloat) -> CGFloat { round(base * scale) }

    // MARK: – Backgrounds
    static let background    = Color(red: 0.04, green: 0.055, blue: 0.08)   // #0A0E14
    static let surface       = Color(red: 0.067, green: 0.098, blue: 0.133) // #111922
    static let surfaceBorder = Color.white.opacity(0.06)

    // MARK: – Accent
    static let accent = Color(red: 0.33, green: 0.74, blue: 0.77)           // #54BEC4

    // MARK: – Bubbles
    static let assistantBubble       = Color(red: 0.067, green: 0.098, blue: 0.133)
    static let assistantBubbleBorder = Color.white.opacity(0.06)
    static let userBubble            = Color(red: 0.05, green: 0.22, blue: 0.38).opacity(0.5)
    static let userBubbleBorder      = Color(red: 0.33, green: 0.74, blue: 0.77).opacity(0.08)

    // MARK: – Status
    static let online  = Color(red: 0.29, green: 0.87, blue: 0.50)  // #4ADE80
    static let offline = Color.red.opacity(0.7)

    // MARK: – Text
    static let textPrimary   = Color.white
    static let textSecondary = Color.white.opacity(0.7)
    static let textDim       = Color.white.opacity(0.25)
    static let timestamp     = Color(red: 0.33, green: 0.74, blue: 0.77).opacity(0.35)

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
    static var bubbleRadius: CGFloat { scaled(16) }
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

    // MARK: – Haptics
    static func hapticSend()    { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func hapticReceive() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func hapticError()   { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
