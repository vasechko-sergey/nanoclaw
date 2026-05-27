import SwiftUI

/// Path-drawn checkmark shape. Drawn from left edge to mid-bottom to top-right.
struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX * 0.85, y: rect.maxY - 1))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 1))
        }
    }
}

/// Delivery state indicator. Replaces overlapping SF Symbol checkmarks.
struct DeliveryChecks: View {
    let status: DeliveryStatus

    @State private var spinRotation: Double = 0
    @State private var secondCheckOpacity: Double = 1

    var body: some View {
        ZStack {
            switch status {
            case .sending:
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Theme.accent.opacity(0.5),
                            style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .frame(width: 10, height: 10)
                    .rotationEffect(.degrees(spinRotation))
                    .onAppear {
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                            spinRotation = 360
                        }
                    }
            case .sent:
                CheckmarkShape()
                    .stroke(Theme.accent.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    .frame(width: 10, height: 6)
            case .delivered:
                HStack(spacing: -3) {
                    CheckmarkShape()
                        .stroke(Theme.accent.opacity(0.8),
                                style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                        .frame(width: 10, height: 6)
                    CheckmarkShape()
                        .stroke(Theme.accent.opacity(0.8),
                                style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                        .frame(width: 10, height: 6)
                        .opacity(secondCheckOpacity)
                        .onAppear {
                            secondCheckOpacity = 0
                            withAnimation(.easeOut(duration: 0.2)) {
                                secondCheckOpacity = 1
                            }
                        }
                }
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red.opacity(0.9))
            }
        }
        .frame(width: 14, height: 10)
        .animation(.easeOut(duration: 0.2), value: status)
    }
}
