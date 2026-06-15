import SwiftUI

/// Chooses the iPad split layout vs the phone-style stacked flow.
/// Driven by the available window area + horizontal size class — never by
/// `UIScreen.main.bounds` or `UIDevice.orientation`, so it stays correct in
/// Stage Manager, Split View, Slide Over, and rotation.
enum LayoutMode: Equatable {
    /// Orb Hub left pane + chat canvas right pane
    case split
    /// current phone flow (splash -> home -> chat)
    case stacked

    /// Split only when the window is a wide landscape regular-width area.
    /// `width > height` detects a landscape *window* (works in Stage Manager,
    /// where the window may be any shape). 900pt is the floor below which the
    /// chat canvas would be too cramped.
    static func resolve(width: CGFloat, height: CGFloat, horizontalSizeClass: UserInterfaceSizeClass?) -> LayoutMode {
        guard horizontalSizeClass == .regular else { return .stacked }
        guard width > height else { return .stacked }
        guard width >= 900 else { return .stacked }
        return .split
    }
}
