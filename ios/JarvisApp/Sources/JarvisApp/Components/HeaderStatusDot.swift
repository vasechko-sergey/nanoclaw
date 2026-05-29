import SwiftUI

/// Symmetric header status dot — one on each side of the unified header.
/// Left side communicates WebSocket connection state; right side communicates
/// agent phase (processing / listening / speaking / idle). Tapping the dot
/// opens the corresponding side drawer.
struct HeaderStatusDot: View {
    enum Side { case left, right }

    let side: Side
    let isConnected: Bool        // meaningful for .left
    let phase: OrbMood           // meaningful for .right
    let action: () -> Void

    /// Exposed for unit tests. Production rendering uses the same value via
    /// `fillColor` inside `body`.
    var resolvedFillColor: Color {
        switch side {
        case .left:
            return isConnected ? Theme.online : Theme.offline
        case .right:
            switch phase {
            case .processing, .listening, .speaking: return Theme.accent
            case .error:                             return Theme.offline
            default:                                 return Theme.accentMedium
            }
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(resolvedFillColor.opacity(0.2), lineWidth: Theme.lineAccent)
                    .frame(width: Theme.scaled(22), height: Theme.scaled(22))
                Circle()
                    .fill(resolvedFillColor)
                    .frame(width: Theme.scaled(8), height: Theme.scaled(8))
                    .shadow(color: resolvedFillColor.opacity(0.8), radius: 4)
            }
            .frame(width: Theme.minTapSize, height: Theme.minTapSize)
        }
    }
}
