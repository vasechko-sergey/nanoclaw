// Sources/JarvisApp/PosingCoach/PosingOverlay.swift
import SwiftUI

struct PosingOverlay: View {
    let hints: [Hint]

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Path { p in
                    let w = geo.size.width, h = geo.size.height
                    for f in [1.0/3, 2.0/3] {
                        p.move(to: CGPoint(x: w*f, y: 0)); p.addLine(to: CGPoint(x: w*f, y: h))
                        p.move(to: CGPoint(x: 0, y: h*f)); p.addLine(to: CGPoint(x: w, y: h*f))
                    }
                }
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
            }
            VStack {
                Spacer()
                VStack(spacing: 8) {
                    ForEach(hints, id: \.code) { hint in
                        Text(hint.text)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(hint.severity == .warn ? Color(red: 1, green: 0.72, blue: 0.3)
                                                               : Color(red: 0.24, green: 0.86, blue: 0.52),
                                        in: Capsule())
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .allowsHitTesting(false)
    }
}
