import SwiftUI
import UIKit

/// Round avatar: uploaded image (local bytes or remote URL) > emoji > initial of the nickname.
struct AvatarView: View {
    var emoji: String?
    var imageData: Data?
    var imageURL: URL?
    var name: String
    var size: CGFloat = 80

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.15))
            content
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if let data = imageData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if let url = imageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let emoji = emoji, !emoji.isEmpty {
            Text(emoji).font(.system(size: size * 0.5))
        } else {
            Text(String(name.trimmed.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accentColor)
        }
    }
}

/// Small pill used for the level and genres.
struct ProfileChip: View {
    let text: String
    var systemImage: String?
    var prominent = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(prominent ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15), in: Capsule())
    }
}

struct ProfileStatCell: View {
    let value: String
    let title: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
