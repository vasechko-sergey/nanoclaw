import SwiftUI

/// A single 0-100 metric ring (conic-style progress + value + caption).
struct RingView: View {
    let value: Int?
    let caption: String
    let color: Color
    var size: CGFloat = 46

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.gray.opacity(0.22), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: CGFloat(value ?? 0) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value.map(String.init) ?? "—")
                    .font(.system(size: size * 0.28, weight: .bold))
                    .foregroundColor(.primary)
            }
            .frame(width: size, height: size)
            Text(caption).font(.system(size: 8)).foregroundColor(.secondary)
        }
    }
}
