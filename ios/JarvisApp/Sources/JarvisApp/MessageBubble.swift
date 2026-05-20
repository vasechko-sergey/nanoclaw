import SwiftUI

private let jarvisBackground = Color(red: 0.07, green: 0.17, blue: 0.16)
private let userBubble = Color(red: 0, green: 0.48, blue: 0.44)
private let tealTime = Color(red: 0, green: 0.82, blue: 0.75).opacity(0.6)

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                switch message.content {
                case .text(let text):
                    Text(text)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(message.role == .user ? userBubble : jarvisBackground)
                        .foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                case .image(let img, _):
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(tealTime)
            }
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}

struct TypingIndicator: View {
    var body: some View {
        HStack {
            GIFView(name: "load")
                .frame(width: 120, height: 120)
            Spacer()
        }
    }
}
