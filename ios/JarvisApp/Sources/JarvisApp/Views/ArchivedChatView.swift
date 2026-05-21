import SwiftUI

struct ArchivedChatView: View {
    let conversation: Conversation
    let messages: [ChatMessage]
    var onNewChatAboutTopic: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: Theme.fontBody))
                        .foregroundStyle(Theme.accentMedium)
                        .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                }

                Spacer()

                VStack(spacing: 1) {
                    Text(conversation.title)
                        .font(.system(size: Theme.fontSubhead, weight: .medium))
                        .foregroundStyle(Theme.textPrimary.opacity(0.7))
                        .lineLimit(1)
                    Text(formattedDate(conversation.createdAt))
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.accentMedium)
                }

                Spacer()

                // Spacer for symmetry
                Color.clear.frame(width: Theme.minTapSize, height: Theme.minTapSize)
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.vertical, Theme.messagePadV)
            .background(Theme.background)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.accent.opacity(0.08))
                    .frame(height: 0.5)
            }

            // Messages (dimmed)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.scaled(8)) {
                    ForEach(messages.filter(\.isVisible)) { msg in
                        MessageBubble(message: msg)
                            .opacity(0.7)
                    }
                }
                .padding(.horizontal)
                .padding(.top, Theme.scaled(8))
                .padding(.bottom, Theme.hPadding)
            }
            .scrollContentBackground(.hidden)

            // Read-only footer
            VStack(spacing: Theme.scaled(8)) {
                HStack(spacing: Theme.scaled(4)) {
                    Image(systemName: "lock")
                        .font(.system(size: Theme.fontCaption))
                    Text("Архивный диалог")
                        .font(.system(size: Theme.fontCaption))
                }
                .foregroundStyle(Theme.accentMedium)

                Button {
                    onNewChatAboutTopic()
                } label: {
                    HStack(spacing: Theme.scaled(5)) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: Theme.fontSubhead))
                        Text("Новый чат на эту тему")
                            .font(.system(size: Theme.fontSubhead))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, Theme.hPadding)
                    .padding(.vertical, Theme.scaled(12))
                    .background(Theme.accent.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.chipRadius)
                            .stroke(Theme.accentSubtle.opacity(0.3), lineWidth: 0.5)
                    )
                }
                .frame(minHeight: Theme.minTapSize)
            }
            .padding(.vertical, Theme.scaled(12))
            .frame(maxWidth: .infinity)
            .background(Theme.background.opacity(0.95))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Theme.accent.opacity(0.06))
                    .frame(height: 0.5)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func formattedDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "сегодня, " + date.formatted(date: .omitted, time: .shortened)
        } else if cal.isDateInYesterday(date) {
            return "вчера, " + date.formatted(date: .omitted, time: .shortened)
        } else {
            return date.formatted(.dateTime.day().month(.abbreviated).year())
        }
    }
}
