import SwiftUI

struct ConversationListView: View {
    @ObservedObject var store: ConversationStore
    var onAction: (ConversationAction) -> Void

    @State private var searchText = ""
    @State private var archivedConversation: Conversation? = nil
    @State private var conversationToDelete: Conversation? = nil
    @Environment(\.dismiss) private var dismiss

    private var filtered: [Conversation] {
        guard !searchText.isEmpty else { return store.conversations }
        let q = searchText.lowercased()
        return store.conversations.filter {
            $0.title.lowercased().contains(q) || $0.preview.lowercased().contains(q)
        }
    }

    private var grouped: [(String, [Conversation])] {
        let calendar = Calendar.current
        let now = Date()
        var pinned:    [Conversation] = []
        var today:     [Conversation] = []
        var yesterday: [Conversation] = []
        var thisWeek:  [Conversation] = []
        var older:     [Conversation] = []

        for conv in filtered {
            if conv.isPinned {
                pinned.append(conv)
            } else if calendar.isDateInToday(conv.lastMessageAt) {
                today.append(conv)
            } else if calendar.isDateInYesterday(conv.lastMessageAt) {
                yesterday.append(conv)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                      conv.lastMessageAt > weekAgo {
                thisWeek.append(conv)
            } else {
                older.append(conv)
            }
        }

        var result: [(String, [Conversation])] = []
        if !pinned.isEmpty    { result.append(("Закреплённые", pinned)) }
        if !today.isEmpty     { result.append(("Сегодня", today)) }
        if !yesterday.isEmpty { result.append(("Вчера", yesterday)) }
        if !thisWeek.isEmpty  { result.append(("Эта неделя", thisWeek)) }
        if !older.isEmpty     { result.append(("Ранее", older)) }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: Theme.fontBody))
                        .foregroundStyle(Theme.accent.opacity(0.5))
                        .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                }

                Spacer()

                Text("Диалоги")
                    .font(.system(size: Theme.fontBody, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.8))

                Spacer()

                Button {
                    onAction(.newChat)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: Theme.scaled(22)))
                        .foregroundStyle(Theme.accent.opacity(0.6))
                        .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                }
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.vertical, Theme.scaled(12))

            // Search
            HStack(spacing: Theme.scaled(8)) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Theme.fontSubhead))
                    .foregroundStyle(Theme.accent.opacity(0.3))
                TextField("Поиск по диалогам...", text: $searchText)
                    .font(.system(size: Theme.fontSubhead))
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
            }
            .padding(.horizontal, Theme.scaled(10))
            .padding(.vertical, Theme.scaled(7))
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .stroke(Theme.surfaceBorder, lineWidth: 0.5)
            )
            .padding(.horizontal, Theme.hPadding)
            .padding(.bottom, Theme.scaled(12))

            // List
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // New chat button (prominent)
                    Button {
                        onAction(.newChat)
                    } label: {
                        HStack(spacing: Theme.scaled(10)) {
                            ZStack {
                                Circle()
                                    .stroke(Theme.accent.opacity(0.3), lineWidth: 0.5)
                                    .frame(width: Theme.scaled(32), height: Theme.scaled(32))
                                Image(systemName: "plus")
                                    .font(.system(size: Theme.fontChip))
                                    .foregroundStyle(Theme.accent.opacity(0.6))
                            }
                            Text("Новый чат")
                                .font(.system(size: Theme.fontSubhead, weight: .medium))
                                .foregroundStyle(Theme.accent.opacity(0.7))
                            Spacer()
                        }
                        .padding(.horizontal, Theme.hPadding)
                        .padding(.vertical, Theme.messagePadV)
                    }

                    Divider().background(Theme.accent.opacity(0.06)).padding(.horizontal, Theme.hPadding)

                    // Grouped conversations
                    ForEach(grouped, id: \.0) { group, conversations in
                        sectionHeader(group)

                        ForEach(conversations) { conv in
                            conversationRow(conv)
                        }
                    }

                    if filtered.isEmpty && !searchText.isEmpty {
                        Text("Ничего не найдено")
                            .font(.system(size: Theme.fontSubhead))
                            .foregroundStyle(Theme.textDim)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
            }
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $archivedConversation) { conv in
            ArchivedChatView(
                conversation: conv,
                messages: store.loadMessages(for: conv.id)
            ) {
                archivedConversation = nil
                let summary = conv.preview.isEmpty ? conv.title : conv.preview
                onAction(.newChatWithContext(summary))
            }
        }
        .alert("Удалить диалог?", isPresented: Binding(
            get: { conversationToDelete != nil },
            set: { if !$0 { conversationToDelete = nil } }
        )) {
            Button("Отмена", role: .cancel) { conversationToDelete = nil }
            Button("Удалить", role: .destructive) {
                if let conv = conversationToDelete {
                    withAnimation(.spring(duration: 0.3)) {
                        store.deleteConversation(conv.id)
                    }
                    conversationToDelete = nil
                }
            }
        } message: {
            Text("Диалог «\(conversationToDelete?.title ?? "")» будет удалён безвозвратно.")
        }
    }

    // MARK: – Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: Theme.fontSmall, weight: .medium))
            .tracking(1)
            .foregroundStyle(Theme.accent.opacity(0.3))
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, Theme.scaled(14))
            .padding(.bottom, Theme.scaled(6))
    }

    private func conversationRow(_ conv: Conversation) -> some View {
        let isActive = conv.id == store.activeConversationId

        return Button {
            if isActive {
                dismiss()
            } else {
                archivedConversation = conv
            }
        } label: {
            HStack(alignment: .top, spacing: Theme.scaled(10)) {
                // Active indicator
                Circle()
                    .fill(isActive ? Theme.accent.opacity(0.5) : Theme.accent.opacity(0.15))
                    .frame(width: Theme.scaled(6), height: Theme.scaled(6))
                    .padding(.top, Theme.scaled(7))

                VStack(alignment: .leading, spacing: Theme.scaled(3)) {
                    HStack(spacing: Theme.scaled(4)) {
                        if conv.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: Theme.scaled(9)))
                                .foregroundStyle(Theme.accent.opacity(0.4))
                        }
                        Text(conv.title)
                            .font(.system(size: Theme.fontSubhead, weight: isActive ? .medium : .regular))
                            .foregroundStyle(Theme.textPrimary.opacity(isActive ? 0.9 : 0.7))
                            .lineLimit(1)
                    }

                    if !conv.preview.isEmpty {
                        Text(conv.preview)
                            .font(.system(size: Theme.fontCaption))
                            .foregroundStyle(Theme.textPrimary.opacity(0.3))
                            .lineLimit(1)
                    }

                    Text(formattedDate(conv.lastMessageAt) + " · \(conv.messageCount) сообщ.")
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.accent.opacity(0.2))
                }

                Spacer()
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.vertical, Theme.scaled(12))
            .background(isActive ? Theme.accent.opacity(0.04) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.scaled(8)))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                conversationToDelete = conv
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                withAnimation(.spring(duration: 0.25)) {
                    store.togglePin(conv.id)
                }
            } label: {
                Label(conv.isPinned ? "Открепить" : "Закрепить",
                      systemImage: conv.isPinned ? "pin.slash" : "pin")
            }
            .tint(Theme.accent)
        }
        .contextMenu {
            if !isActive {
                Button {
                    archivedConversation = conv
                } label: {
                    Label("Открыть", systemImage: "eye")
                }

                Button {
                    let summary = conv.preview.isEmpty ? conv.title : conv.preview
                    onAction(.newChatWithContext(summary))
                } label: {
                    Label("Новый чат на эту тему", systemImage: "plus.bubble")
                }

                Button {
                    store.togglePin(conv.id)
                } label: {
                    Label(conv.isPinned ? "Открепить" : "Закрепить",
                          systemImage: conv.isPinned ? "pin.slash" : "pin")
                }

                Divider()

                Button(role: .destructive) {
                    conversationToDelete = conv
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if cal.isDateInYesterday(date) {
            return "вчера, " + date.formatted(date: .omitted, time: .shortened)
        } else {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
