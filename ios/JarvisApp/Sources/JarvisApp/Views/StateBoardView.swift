import SwiftUI

struct StateBoardView: View {
    @ObservedObject var service: StateService
    @State private var expanded: Set<String> = []

    enum Freshness { case today, stale, unknown }
    static func freshness(updated: String?, today: String) -> Freshness {
        guard let u = updated else { return .unknown }
        return u == today ? .today : .stale
    }

    private static func todayKey() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    private func accent(_ key: String) -> Color {
        switch key {
        case "greg": return .green; case "gordon": return .orange
        case "payne": return .purple; case "scrooge": return .yellow
        default: return .blue
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let lv = service.state?.levels {
                    HStack(spacing: 14) {
                        RingView(value: lv.energy, caption: "энергия", color: .orange)
                        RingView(value: lv.stress, caption: "стресс", color: .teal)
                        RingView(value: lv.recovery, caption: "восст.", color: .green)
                        RingView(value: lv.readiness, caption: "готовн.", color: Color(red: 0.6, green: 0.84, blue: 0.29))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                ForEach(service.state?.agents ?? []) { a in
                    rowView(a)
                }
            }
        }
        .navigationTitle("Состояние")
        .onAppear { service.refresh() }
    }

    @ViewBuilder
    private func rowView(_ a: StateModel.AgentRow) -> some View {
        let isOpen = expanded.contains(a.key)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(a.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.title).font(.system(size: 13, weight: .bold))
                    if let s = a.summary { Text(s).font(.system(size: 11)).foregroundColor(.secondary) }
                    if isOpen {
                        if let d = a.detail { Text(d).font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 2) }
                        if a.key == "greg", let series = service.state?.levels.recovery7d, series.count > 1 {
                            Sparkline(values: series).stroke(Color.green, lineWidth: 2).frame(height: 26).padding(.top, 4)
                        }
                    }
                }
                Spacer()
                Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 10)).foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { if isOpen { expanded.remove(a.key) } else { expanded.insert(a.key) } }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .overlay(Rectangle().frame(width: 3).foregroundColor(accent(a.key)), alignment: .leading)
        .opacity(Self.freshness(updated: a.updated, today: Self.todayKey()) == .stale ? 0.6 : 1)
        Divider()
    }
}

/// Normalized 0-100 series → path in unit rect.
struct Sparkline: Shape {
    let values: [Int]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let maxV = max(values.max() ?? 100, 1)
        let step = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: rect.minX + CGFloat(i) * step,
                             y: rect.maxY - (CGFloat(v) / CGFloat(maxV)) * rect.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
