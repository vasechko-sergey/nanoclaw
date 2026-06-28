import SwiftUI

/// Slim home-screen entry that replaces the 4-ring health strip. Shows the
/// count of agents with a daily action and opens the full dashboard on tap.
struct SummaryEntryView: View {
    let agents: [StateModel.AgentRow]

    private var count: Int { StateBoardView.actionableCount(agents) }

    var body: some View {
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
        .padding(.horizontal, Theme.scaled(14))
        .padding(.vertical, Theme.scaled(11))
        .background(Theme.surface, in: Capsule())
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
