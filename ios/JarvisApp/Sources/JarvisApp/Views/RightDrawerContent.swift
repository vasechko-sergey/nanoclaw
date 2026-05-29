import SwiftUI

/// Single-`ScrollView` right drawer with three sections: Profile, Context,
/// Settings. Mirrors the structure of `DrawerContent` (left drawer) so the
/// language of the app is symmetric: every top-level navigation lives in a
/// side drawer.
struct RightDrawerContent: View {
    @Environment(AppSettings.self) var settings
    var store: ConversationStore
    let isConnected: Bool
    var onReconnect: () -> Void
    var onConversationAction: ((ConversationAction) -> Void)? = nil

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Header with title — symmetry with left drawer's "Диалоги"
                header

                // PROFILE
                sectionHeader("Профиль")
                ProfileFormBody(store: store, isConnected: isConnected, onReconnect: onReconnect)
                    .padding(.bottom, Theme.scaled(12))

                // CONTEXT — placeholder until proactive spec adds the real rows
                sectionHeader("Контекст")
                contextPlaceholder
                    .padding(.bottom, Theme.scaled(12))

                // SETTINGS
                sectionHeader("Настройки")
                SettingsFormBody(store: store, onConversationAction: onConversationAction)
                    .padding(.bottom, Theme.scaled(20))
            }
        }
        .background(Color(red: 0.04, green: 0.08, blue: 0.11))
        .accessibilityIdentifier("right-drawer")
    }

    private var header: some View {
        HStack {
            Text("Профиль и настройки")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
            Spacer()
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.metaFont)
            .tracking(1)
            .foregroundStyle(Theme.accentMedium)
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, Theme.scaled(14))
            .padding(.bottom, Theme.scaled(6))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Placeholder Context section — the proactive spec replaces this with live
    /// per-source toggles (location / health / calendar) plus a "force pull"
    /// button. For now the block tells the user what will live here.
    private var contextPlaceholder: some View {
        VStack(alignment: .leading, spacing: Theme.scaled(6)) {
            Text("Здесь появятся живые сигналы устройства, которые видит Джарвис: геолокация, здоровье, ближайшее событие в календаре.")
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.hPadding)
        }
    }
}
