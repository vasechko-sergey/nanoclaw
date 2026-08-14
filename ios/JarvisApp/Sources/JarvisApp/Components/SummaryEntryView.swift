import SwiftUI

/// Slim home-screen entry. Carries the three numbers the owner acts on —
/// stress, how unusual today is, recovery — because behind a tap they went
/// unread. Tapping still opens the full dashboard.
struct SummaryEntryView: View {
    let agents: [StateModel.AgentRow]
    let levels: StateModel.Levels

    private var count: Int { StateBoardView.actionableCount(agents) }

    /// (value, label) in reading order. Pure, so the copy is testable without a
    /// view host. `illness` is a percentile of his own history — the label says
    /// «необычность», never «риск», because there is nothing to calibrate a
    /// probability against.
    static func tiles(_ l: StateModel.Levels) -> [(String, String)] {
        let show: (Int?) -> String = { $0.map(String.init) ?? "—" }
        return [(show(l.stress), "стресс"), (show(l.illness), "необычность"), (show(l.recovery), "восстановление")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.scaled(8)) {
            HStack(spacing: 9) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: Theme.fontSubhead))
                    .foregroundColor(Theme.accent)
                Text(count > 0 ? "Сводка · \(count) \(Self.plural(count))" : "Сводка")
                    .font(.system(size: Theme.fontSubhead))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.fontCaption))
                    .foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: Theme.scaled(16)) {
                ForEach(Self.tiles(levels), id: \.1) { tile in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tile.0)
                            .font(.system(size: Theme.fontSubhead, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                        Text(tile.1)
                            .font(.system(size: Theme.fontCaption))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                Spacer()
            }
        }
        .padding(.horizontal, Theme.scaled(14))
        .padding(.vertical, Theme.scaled(11))
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.scaled(18)))
        .accessibilityIdentifier("home-summary-entry")
    }

    /// Russian plural for "дело" (1 дело / 2 дела / 5 дел).
    static func plural(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "дело" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "дела" }
        return "дел"
    }
}
