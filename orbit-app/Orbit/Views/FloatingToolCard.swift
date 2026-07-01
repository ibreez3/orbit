import SwiftUI

struct FloatingToolCard<Content: View>: View {
    let title: String
    let subtitle: String
    let onPin: () -> Void
    let onExpand: () -> Void
    let onClose: () -> Void
    private let content: () -> Content

    init(
        title: String,
        subtitle: String,
        onPin: @escaping () -> Void,
        onExpand: @escaping () -> Void,
        onClose: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onPin = onPin
        self.onExpand = onExpand
        self.onClose = onClose
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                iconButton("pin", action: onPin, help: "Pin")
                iconButton("arrow.up.left.and.arrow.down.right", action: onExpand, help: "Expand")
                iconButton("xmark", action: onClose, help: "Close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            content()
        }
        .frame(width: 390, height: 460)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 14)
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void, help: String) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
