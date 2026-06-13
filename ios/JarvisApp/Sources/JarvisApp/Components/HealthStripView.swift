import SwiftUI

/// Compact 4-ring glance strip for the home screen. Taps open the full board.
struct HealthStripView: View {
    let levels: StateModel.Levels?
    var body: some View {
        HStack(spacing: 18) {
            RingView(value: levels?.energy, caption: "эн", color: .orange, size: 34)
            RingView(value: levels?.stress, caption: "стр", color: .teal, size: 34)
            RingView(value: levels?.recovery, caption: "вос", color: .green, size: 34)
            RingView(value: levels?.readiness, caption: "гот", color: Color(red: 0.6, green: 0.84, blue: 0.29), size: 34)
        }
        .padding(.vertical, 8).padding(.horizontal, 14)
        .background(Color.gray.opacity(0.12), in: Capsule())
    }
}
