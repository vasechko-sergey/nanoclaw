import SwiftUI

struct ConversationListView: View {
    var store: ConversationStore
    var onAction: (ConversationAction) -> Void

    @State private var searchText = ""
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
                        .foregroundStyle(Theme.accentMedium)
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
                        .foregroundStyle(Theme.accent)
                        .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                }
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.vertical, Theme.scaled(12))

            // Search
            HStack(spacing: Theme.scaled(8)) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Theme.fontSubhead))
                    .foregroundStyle(Theme.accentMedium)
                TextField("Поиск в архиве...", text: $searchText)
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
                    .stroke(Theme.surfaceBorder, lineWidth: Theme.lineHairline)
            )
            .padding(.horizontal, Theme.hPadding)
            .padding(.bottom, Theme.scaled(12))

            // List (List required for swipeActions to work)
            List {
                // New chat button
                Button {
                    onAction(.newChat)
                } label: {
                    HStack(spacing: Theme.scaled(10)) {
                        ZStack {
                            Circle()
                                .fill(Theme.accent.opacity(0.08))
                                .frame(width: Theme.scaled(32), height: Theme.scaled(32))
                            Circle()
                                .stroke(Theme.accentMedium, lineWidth: Theme.lineHairline)
                                .frame(width: Theme.scaled(32), height: Theme.scaled(32))
                            Image(systemName: "plus")
                                .font(.system(size: Theme.fontChip))
                                .foregroundStyle(Theme.accent)
                        }
                        Text("Новый чат")
                            .font(.system(size: Theme.fontSubhead, weight: .medium))
                            .foregroundStyle(Theme.accent)
                        Spacer()
                    }
                    .padding(.vertical, Theme.messagePadV)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: Theme.hPadding, bottom: 0, trailing: Theme.hPadding))

                // Grouped conversations
                ForEach(grouped, id: \.0) { group, conversations in
                    Section {
                        ForEach(conversations) { conv in
                            conversationRow(conv)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                    } header: {
                        sectionHeader(group)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                    .listSectionSeparator(.hidden)
                }

                if filtered.isEmpty && !searchText.isEmpty {
                    Text("Ничего не найдено")
                        .font(.system(size: Theme.fontSubhead))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
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
            .foregroundStyle(Theme.accentMedium)
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, Theme.scaled(14))
            .padding(.bottom, Theme.scaled(6))
    }

    private func conversationRow(_ conv: Conversation) -> some View {
        let isActive = conv.id == store.activeConversationId

        return Button {
            onAction(.open(conv))
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: Theme.scaled(10)) {
                // Active indicator
                Circle()
                    .fill(isActive ? Theme.accentMedium : Theme.accentSubtle.opacity(0.3))
                    .frame(width: Theme.scaled(6), height: Theme.scaled(6))
                    .padding(.top, Theme.scaled(7))

                VStack(alignment: .leading, spacing: Theme.scaled(3)) {
                    HStack(spacing: Theme.scaled(4)) {
                        if conv.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: Theme.scaled(9)))
                                .foregroundStyle(Theme.accentMedium)
                        }
                        Text(conv.title)
                            .font(.system(size: Theme.fontSubhead, weight: isActive ? .medium : .regular))
                            .foregroundStyle(Theme.textPrimary.opacity(isActive ? 0.9 : 0.7))
                            .lineLimit(1)
                    }

                    if !conv.preview.isEmpty {
                        Text(conv.preview)
                            .font(.system(size: Theme.fontCaption))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }

                    Text(formattedDate(conv.lastMessageAt) + " · \(conv.messageCount) сообщ.")
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.accentMedium)
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
                    onAction(.open(conv))
                    dismiss()
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

/// Drawer-friendly version of the conversation list — same logic, no full-screen chrome.
/// Hosted as a sliding overlay from ChatView, not as a sheet.
struct DrawerContent: View {
    var store: ConversationStore
    var onAction: (ConversationAction) -> Void
    var onSettings: () -> Void = {}

    @State private var searchText = ""
    @State private var conversationToDelete: Conversation? = nil

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
        var pinned: [Conversation] = []
        var today: [Conversation] = []
        var yesterday: [Conversation] = []
        var thisWeek: [Conversation] = []
        var older: [Conversation] = []
        for conv in filtered {
            if conv.isPinned { pinned.append(conv) }
            else if calendar.isDateInToday(conv.lastMessageAt) { today.append(conv) }
            else if calendar.isDateInYesterday(conv.lastMessageAt) { yesterday.append(conv) }
            else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                    conv.lastMessageAt > weekAgo { thisWeek.append(conv) }
            else { older.append(conv) }
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
                Text("Диалоги")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                Spacer()
                Button { onAction(.newChat) } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accentMedium)
                TextField("Поиск в архиве...", text: $searchText)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.accent.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.15), lineWidth: Theme.lineHairline))
            .padding(.horizontal, Theme.hPadding)
            .padding(.bottom, 12)

            // Empty state
            if store.conversations.isEmpty {
                Spacer()
                Text("Нет диалогов")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(grouped, id: \.0) { group, conversations in
                        Section {
                            ForEach(conversations) { conv in
                                drawerRow(conv)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            }
                        } header: {
                            Text(group.uppercased())
                                .font(Theme.metaFont)
                                .tracking(1)
                                .foregroundStyle(Theme.accentMedium)
                                .padding(.horizontal, Theme.hPadding)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                        .listSectionSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            // Settings footer
            Divider().background(Theme.hairlineColor)
            Button(action: onSettings) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text("Настройки")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.accentMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.hPadding)
                .padding(.vertical, 14)
            }
        }
        .background(Color(red: 0.04, green: 0.08, blue: 0.11))
        .accessibilityIdentifier("conv-drawer")
        .alert("Удалить диалог?", isPresented: Binding(
            get: { conversationToDelete != nil },
            set: { if !$0 { conversationToDelete = nil } }
        )) {
            Button("Отмена", role: .cancel) { conversationToDelete = nil }
            Button("Удалить", role: .destructive) {
                if let conv = conversationToDelete {
                    withAnimation(.spring(duration: 0.3)) { store.deleteConversation(conv.id) }
                    conversationToDelete = nil
                }
            }
        } message: {
            Text("Диалог «\(conversationToDelete?.title ?? "")» будет удалён безвозвратно.")
        }
    }

    private func drawerRow(_ conv: Conversation) -> some View {
        let isActive = conv.id == store.activeConversationId
        return Button {
            onAction(.open(conv))
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(isActive ? Theme.accent : Theme.accent.opacity(0.3))
                    .frame(width: 6, height: 6)
                    .shadow(color: isActive ? Theme.accent.opacity(0.6) : .clear, radius: 3)
                    .padding(.top, 7)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if conv.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.accentMedium)
                        }
                        Text(conv.title)
                            .font(.system(size: 14, weight: isActive ? .medium : .regular))
                            .foregroundStyle(Theme.textPrimary.opacity(isActive ? 0.9 : 0.7))
                            .lineLimit(1)
                    }
                    if !conv.preview.isEmpty {
                        Text(conv.preview)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Text(formattedDate(conv.lastMessageAt) + " · \(conv.messageCount) сообщ.")
                        .font(Theme.metaFont)
                        .foregroundStyle(Theme.accentMedium)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.vertical, 12)
            .background(isActive ? Theme.accent.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityIdentifier("conv-row-\(conv.id.uuidString)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                conversationToDelete = conv
            } label: { Label("Удалить", systemImage: "trash") }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                withAnimation(.spring(duration: 0.25)) { store.togglePin(conv.id) }
            } label: {
                Label(conv.isPinned ? "Открепить" : "Закрепить",
                      systemImage: conv.isPinned ? "pin.slash" : "pin")
            }
            .tint(Theme.accent)
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
