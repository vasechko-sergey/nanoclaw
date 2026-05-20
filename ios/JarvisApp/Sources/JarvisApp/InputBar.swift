import SwiftUI

private let teal = Color(red: 0, green: 0.82, blue: 0.75)
private let inputBg = Color(red: 0.07, green: 0.17, blue: 0.16)

struct InputBar: View {
    @Binding var text: String
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Сообщение...", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .foregroundStyle(Color.white)
                .tint(teal)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 20))

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(teal)
                    .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.25 : 1.0)
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(red: 0.04, green: 0.1, blue: 0.09))
    }
}
