import SwiftUI

/// The agent dashboard — one card per agent (picker order), each with metric
/// chips and one daily action; tap a card to expand its detail text. Replaces
/// the old 4-ring health glance.
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

    enum MetricTone: Equatable {
        case ok, warn, bad, neutral
        static func parse(_ t: String?) -> MetricTone {
            switch t {
            case "ok":   return .ok
            case "warn": return .warn
            case "bad":  return .bad
            default:     return .neutral
            }
        }
    }

    static func showsAction(_ action: String?) -> Bool {
        guard let a = action?.trimmingCharacters(in: .whitespaces), !a.isEmpty, a != "—" else { return false }
        return true
    }

    static func actionableCount(_ agents: [StateModel.AgentRow]) -> Int {
        agents.filter { showsAction($0.action) }.count
    }

    private func identity(_ key: String) -> AgentIdentity? { AgentIdentity(rawValue: key) }
    private func accent(_ key: String) -> Color { identity(key)?.accentColor ?? Theme.accent }

    private func toneColor(_ tone: MetricTone) -> Color {
        switch tone {
        case .ok:      return AgentIdentity.greg.accentColor      // sage
        case .warn:    return AgentIdentity.scrooge.accentColor   // gold
        case .bad:     return AgentIdentity.gordon.accentColor    // tomato
        case .neutral: return Theme.textPrimary
        }
    }

    private func headerTitle(_ a: StateModel.AgentRow) -> String {
        if let id = identity(a.key) { return "\(id.displayName) · \(id.profession)" }
        return a.title
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.scaled(10)) {
                ForEach(service.state?.agents ?? []) { a in
                    cardView(a)
                }
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.vertical, Theme.scaled(12))
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Сводка")
        .onAppear { service.refresh() }
    }

    @ViewBuilder
    private func cardView(_ a: StateModel.AgentRow) -> some View {
        let isOpen = expanded.contains(a.key)
        let ac = accent(a.key)
        let stale = Self.freshness(updated: a.updated, today: Self.todayKey()) == .stale

        VStack(alignment: .leading, spacing: Theme.scaled(9)) {
            HStack(spacing: 8) {
                Image(systemName: identity(a.key)?.dashIcon ?? "circle")
                    .font(.system(size: Theme.fontSubhead))
                    .foregroundColor(ac)
                Text(headerTitle(a))
                    .font(.system(size: Theme.fontSubhead, weight: .semibold))
                    .foregroundColor(ac)
                Spacer()
                Circle().fill(stale ? Theme.textSecondary : Theme.online)
                    .frame(width: 6, height: 6)
                if let u = a.updated {
                    Text(u).font(.system(size: Theme.fontCaption)).foregroundColor(Theme.textSecondary)
                }
            }

            if let metrics = a.metrics, !metrics.isEmpty {
                HStack(spacing: 7) {
                    ForEach(Array(metrics.enumerated()), id: \.offset) { _, m in chip(m) }
                }
            }

            if Self.showsAction(a.action), let action = a.action {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right").font(.system(size: Theme.fontCaption))
                    Text(action).font(.system(size: Theme.fontCaption))
                    Spacer(minLength: 0)
                }
                .foregroundColor(ac)
            }

            if isOpen {
                if let d = a.detail, !d.isEmpty {
                    MarkdownText(d, fontSize: Theme.fontCaption)
                        .padding(.top, 2)
                }
                if a.key == "greg", let series = service.state?.levels.recovery7d, series.count > 1 {
                    Sparkline(values: series)
                        .stroke(AgentIdentity.greg.accentColor, lineWidth: 2)
                        .frame(height: 26).padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, Theme.scaled(13))
        .padding(.vertical, Theme.scaled(11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(Theme.surfaceBorder, lineWidth: 0.5)
        )
        .opacity(stale ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if isOpen { expanded.remove(a.key) } else { expanded.insert(a.key) } }
    }

    @ViewBuilder
    private func chip(_ m: StateModel.Metric) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(m.v)
                .font(.system(size: Theme.fontSubhead, weight: .semibold))
                .foregroundColor(toneColor(MetricTone.parse(m.t)))
            Text(m.l)
                .font(.system(size: Theme.fontCaption))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Normalized 0-100 series → path in unit rect. Used for Greg's recovery7d.
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
