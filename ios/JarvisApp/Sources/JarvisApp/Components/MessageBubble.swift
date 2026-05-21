import SwiftUI
import UIKit

struct MessageBubble: View {
    let message: ChatMessage
    var onImageTap: ((UIImage) -> Void)? = nil
    var onFeedback: ((String, Bool) -> Void)? = nil  // (messageId, isPositive)

    @State private var feedback: FeedbackState = .none

    private enum FeedbackState { case none, positive, negative }
    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: Theme.scaled(48)) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                switch message.content {
                case .text(let text):
                    Group {
                        if isUser {
                            Text(text)
                                .font(.system(size: Theme.fontBody))
                        } else {
                            MarkdownText(text, fontSize: Theme.fontBody)
                        }
                    }
                    .padding(.horizontal, Theme.messagePadH)
                    .padding(.vertical, Theme.messagePadV)
                    .background(isUser ? Theme.userBubble : Theme.assistantBubble)
                    .foregroundStyle(Theme.textPrimary.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                            .stroke(isUser ? Theme.userBubbleBorder : Theme.assistantBubbleBorder, lineWidth: 0.5)
                    )
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = text
                            Theme.hapticSend()
                        } label: {
                            Label("Копировать", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: text) {
                            Label("Поделиться", systemImage: "square.and.arrow.up")
                        }
                    }

                case .image(let img, _):
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: Theme.scaled(260))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius))
                        .onTapGesture { onImageTap?(img) }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.image = img
                                Theme.hapticSend()
                            } label: {
                                Label("Копировать", systemImage: "doc.on.doc")
                            }
                            Button {
                                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                                Theme.hapticSend()
                            } label: {
                                Label("Сохранить в фото", systemImage: "square.and.arrow.down")
                            }
                        }
                }
                HStack(spacing: Theme.scaled(8)) {
                    Text(message.timestamp, style: .time)
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.timestamp)
                        .accessibilityHidden(true)

                    if !isUser {
                        Spacer().frame(width: Theme.scaled(4))
                        feedbackButtons
                    }
                }
            }
            if message.role == .assistant { Spacer(minLength: Theme.scaled(48)) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var feedbackButtons: some View {
        HStack(spacing: Theme.scaled(2)) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    feedback = feedback == .positive ? .none : .positive
                }
                if feedback == .positive { onFeedback?(message.id, true) }
            } label: {
                Image(systemName: feedback == .positive ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .font(.system(size: Theme.scaled(11)))
                    .foregroundStyle(feedback == .positive ? Theme.accent : Theme.accent.opacity(0.2))
                    .frame(width: Theme.scaled(28), height: Theme.scaled(28))
            }
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    feedback = feedback == .negative ? .none : .negative
                }
                if feedback == .negative { onFeedback?(message.id, false) }
            } label: {
                Image(systemName: feedback == .negative ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: Theme.scaled(11)))
                    .foregroundStyle(feedback == .negative ? Theme.offline : Theme.accent.opacity(0.2))
                    .frame(width: Theme.scaled(28), height: Theme.scaled(28))
            }
        }
    }

    private var accessibilityDescription: String {
        let role = isUser ? "Вы" : "Jarvis"
        let time = message.timestamp.formatted(date: .omitted, time: .shortened)
        switch message.content {
        case .text(let text):
            return "\(role): \(text). \(time)"
        case .image(_, let filename):
            return "\(role): изображение \(filename). \(time)"
        }
    }
}

struct TypingIndicator: View {
    @State private var rotation: Double = 0
    @State private var pulse: CGFloat = 1

    var body: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.07))
                    .frame(width: Theme.scaled(32), height: Theme.scaled(32))
                    .scaleEffect(pulse)

                Circle()
                    .trim(from: 0.05, to: 0.88)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [Theme.accent.opacity(0), Theme.accent]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                    .frame(width: Theme.scaled(26), height: Theme.scaled(26))
                    .rotationEffect(.degrees(rotation))

                Circle()
                    .trim(from: 0.1, to: 0.65)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [Theme.accent.opacity(0), Theme.accent.opacity(0.55)]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round)
                    )
                    .frame(width: Theme.scaled(18), height: Theme.scaled(18))
                    .rotationEffect(.degrees(-rotation * 2))

                Circle()
                    .fill(Theme.accent.opacity(0.9))
                    .frame(width: Theme.scaled(4), height: Theme.scaled(4))
                    .scaleEffect(pulse)
            }
            .padding(8)
            Spacer()
        }
        .accessibilityLabel("Jarvis печатает")
        .onAppear {
            withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = 1.35
            }
        }
    }
}
