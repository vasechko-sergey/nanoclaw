import SwiftUI

/// Full-screen terminal "workout done" step. NOT a sheet — finishing is a
/// commit, so there is nothing to minimize to. An explicit "Отмена" returns to
/// the runner (the toolbar "финиш" is tappable mid-workout). Готово commits the
/// session with a worded 1–5 feeling.
struct WorkoutFinishView: View {
    let dayName: String
    let exerciseCount: Int
    let setCount: Int
    var onCancel: () -> Void
    var onDone: (_ feeling: Int, _ label: String) -> Void

    @State private var selected = 4   // default "Хорошо, с запасом"

    /// Dark teal used for text/icons sitting on the accent fill.
    private let onAccent = Color(red: 0.02, green: 0.16, blue: 0.17)

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: onCancel) {
                        Label("Отмена", systemImage: "chevron.left")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Text("к тренировке").font(.caption).foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 16).padding(.top, 10)

                VStack(spacing: 6) {
                    Image(systemName: "flag")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Theme.accent.opacity(0.15)))
                    Text("Тренировка завершена").font(.title3.weight(.medium)).foregroundStyle(.white)
                    Text("\(dayName) · \(exerciseCount) упражнений · \(setCount) подходов")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.5))
                }
                .padding(.top, 26)

                Text("Как прошла?").font(.subheadline).foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 22).padding(.bottom, 4)

                VStack(spacing: 9) {
                    ForEach(WorkoutRunnerLogic.feelings, id: \.value) { f in
                        Button { selected = f.value } label: {
                            HStack(spacing: 10) {
                                Text("\(f.value)")
                                    .font(.caption).frame(width: 16)
                                    .foregroundStyle(selected == f.value ? onAccent : .white.opacity(0.3))
                                Text(f.label)
                                    .font(.body)
                                    .foregroundStyle(selected == f.value ? onAccent : .white.opacity(0.7))
                                if selected == f.value {
                                    Spacer(); Image(systemName: "checkmark").foregroundStyle(onAccent)
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(selected == f.value ? Theme.accent : Color.white.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)

                Spacer()

                Button {
                    let label = WorkoutRunnerLogic.feelings.first { $0.value == selected }?.label ?? ""
                    onDone(selected, label)
                } label: {
                    Text("Готово").font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Capsule().fill(Theme.accent))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 18).padding(.bottom, 22)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("workout-finish-view")
    }
}
