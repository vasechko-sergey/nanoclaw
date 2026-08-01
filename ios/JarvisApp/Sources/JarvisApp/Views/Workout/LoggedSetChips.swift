import SwiftUI

/// Compact chip strip of the current exercise's logged sets + a muted
/// "подход N из M" position chip. Tapping a logged chip opens an action sheet:
/// изменить (fix a wrong weight/reps entry), удалить (drop an accidental set),
/// and — when Payne left a note — показать его совет. Sets with a coach hint
/// keep the accent outline + 💬 badge as before.
struct LoggedSetChips: View {
    let logged: [LoggedSet]
    let currentSetIdx: Int
    let targetSets: Int
    /// Drop the set at this index (mis-entry). Parent maps to the active exercise.
    var onDeleteSet: (Int) -> Void = { _ in }
    /// Correct the set at this index → (setIdx, reps, weight, repsInReserve).
    var onEditSet: (Int, Int, Double, Int) -> Void = { _, _, _, _ in }

    @State private var tappedIdx: Int? = nil    // coach-hint sheet
    @State private var actionIdx: Int? = nil    // изменить / удалить action sheet
    @State private var editIdx: Int? = nil      // edit-values sheet

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(logged.enumerated()), id: \.offset) { idx, s in
                chipButton(idx: idx, set: s)
            }
            if let label = WorkoutRunnerLogic.setLabel(currentSetIdx: currentSetIdx, targetSets: targetSets) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            }
            Spacer(minLength: 0)
        }
        .confirmationDialog(
            actionIdx.map { "Подход \($0 + 1)" } ?? "",
            isPresented: Binding(get: { actionIdx != nil }, set: { if !$0 { actionIdx = nil } }),
            titleVisibility: .visible
        ) {
            if let idx = actionIdx, logged.indices.contains(idx) {
                Button("Изменить вес или повторы") { editIdx = idx; actionIdx = nil }
                if logged[idx].coachHint != nil {
                    Button("Показать совет Пейна") { tappedIdx = idx; actionIdx = nil }
                }
                Button("Удалить подход", role: .destructive) {
                    Theme.hapticSend()
                    onDeleteSet(idx)
                    actionIdx = nil
                }
                Button("Отмена", role: .cancel) { actionIdx = nil }
            }
        }
        .sheet(isPresented: Binding(
            get: { tappedIdx != nil },
            set: { if !$0 { tappedIdx = nil } }
        )) {
            if let idx = tappedIdx, logged.indices.contains(idx),
               let text = logged[idx].coachHint {
                VStack(spacing: 12) {
                    Text("Пейн").font(.caption).foregroundStyle(.white.opacity(0.6))
                    Text(text).font(.body).multilineTextAlignment(.leading)
                    Button("Закрыть") { tappedIdx = nil }
                }
                .padding(20)
                // 180pt is plenty for one or two coach sentences and leaves the
                // running set visible behind it; .medium is there if the text is
                // long. A half/full-screen default buried the runner.
                .presentationDetents([.height(180), .medium])
                .presentationDragIndicator(.visible)
            } else {
                // Race: the hint was cleared (swap / new plan) between the tap
                // and this render. Dismiss instead of showing a blank sheet.
                Color.clear.onAppear { tappedIdx = nil }
            }
        }
        .sheet(isPresented: Binding(
            get: { editIdx != nil },
            set: { if !$0 { editIdx = nil } }
        )) {
            if let idx = editIdx, logged.indices.contains(idx) {
                EditSetSheet(set: logged[idx], setNumber: idx + 1) { reps, weight, rir in
                    onEditSet(idx, reps, weight, rir)
                    editIdx = nil
                }
            } else {
                Color.clear.onAppear { editIdx = nil }
            }
        }
    }

    @ViewBuilder
    private func chipButton(idx: Int, set: LoggedSet) -> some View {
        // Badge marks a set that deviated from plan; the accent outline + tap
        // sheet are driven by Payne's coachHint — separate signals.
        let hasHint = set.coachHint != nil
        Button {
            actionIdx = idx
        } label: {
            HStack(spacing: 4) {
                Text("✓ \(set.reps)×\(WorkoutSetFormat.weight(set.weight))")
                if !set.deviations.isEmpty {
                    // Prominent enough to catch the eye mid-set: 14pt bubble in a
                    // filled 20pt accent circle, not a 10pt tint that blends in.
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.accent))
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.15)))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Theme.accent, lineWidth: hasHint ? 1.5 : 0)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Correct an already-logged set. Same reps/weight wheels + reserve buttons as
/// the live logger (FocusSetCard), prefilled with the set's current values so a
/// mis-picked weight is a two-tap fix. Presented as a medium sheet from the chip
/// action menu; "Сохранить" hands the new numbers back to the coordinator.
private struct EditSetSheet: View {
    let setNumber: Int
    let onSave: (Int, Double, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reps: Int
    @State private var weight: Double
    @State private var rir: Int

    /// Dark teal used for text sitting on the accent fill.
    private let onAccent = Color(red: 0.02, green: 0.16, blue: 0.17)

    init(set: LoggedSet, setNumber: Int, onSave: @escaping (Int, Double, Int) -> Void) {
        self.setNumber = setNumber
        self.onSave = onSave
        _reps = State(initialValue: set.reps)
        _weight = State(initialValue: set.weight)
        _rir = State(initialValue: set.repsInReserve)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Подход \(setNumber)").font(.headline).foregroundStyle(Theme.textPrimary)
                .padding(.top, 4)
            HStack(spacing: 10) {
                wheelColumn(title: "Повторы") {
                    Picker("Повторы", selection: $reps) {
                        ForEach(WorkoutRunnerLogic.repsOptions, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                wheelColumn(title: "Вес, кг") {
                    Picker("Вес", selection: $weight) {
                        ForEach(WorkoutRunnerLogic.weightOptions, id: \.self) { Text(WorkoutSetFormat.weight($0)).tag($0) }
                    }
                }
            }
            rirRow
            Button {
                Theme.hapticSend()
                onSave(reps, weight, rir)
                dismiss()
            } label: {
                Text("Сохранить").font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Capsule().fill(Theme.accent))
            }
            Button("Отмена") { dismiss() }
                .foregroundStyle(.white.opacity(0.6)).font(.subheadline)
        }
        .padding(16)
        .preferredColorScheme(.dark)
        .presentationDetents([.height(360), .medium])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("edit-set-sheet")
    }

    @ViewBuilder
    private func wheelColumn<P: View>(title: String, @ViewBuilder picker: () -> P) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.6))
            picker()
                .pickerStyle(.wheel)
                .frame(height: 100)
                .clipped()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
    }

    private var rirRow: some View {
        HStack {
            Text("Запас").foregroundStyle(.white.opacity(0.65))
            Spacer()
            HStack(spacing: 8) {
                ForEach(WorkoutRunnerLogic.rirButtons, id: \.self) { v in
                    Button { Theme.hapticSend(); rir = v } label: {
                        Text("\(v)")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 40, height: 36)
                            .foregroundStyle(rir == v ? onAccent : .white.opacity(0.6))
                            .background(RoundedRectangle(cornerRadius: 10).fill(rir == v ? Theme.accent : Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
