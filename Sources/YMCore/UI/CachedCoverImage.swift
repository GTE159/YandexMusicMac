import SwiftUI

/// SwiftUI component for smoothly rendering downsampled, cached album art
public struct CachedCoverImage: View {
    let coverUri: String?
    let size: YMCoverSize
    let displaySize: CGFloat
    let cornerRadius: CGFloat

    @UIState private var loadedImage: NSImage? = nil

    public init(
        coverUri: String?,
        size: YMCoverSize = .small,
        displaySize: CGFloat = 40,
        cornerRadius: CGFloat = 6
    ) {
        self.coverUri = coverUri
        self.size = size
        self.displaySize = displaySize
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        Group {
            if let nsImage = loadedImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.secondary.opacity(0.15))
                    Image(systemName: "music.note")
                        .font(.system(size: displaySize * 0.4))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: displaySize, height: displaySize)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: "\(coverUri ?? "")_\(size.rawValue)") {
            loadedImage = nil
            guard let coverUri = coverUri, !coverUri.isEmpty else { return }
            let image = await ImagePipeline.shared.image(for: coverUri, size: size)
            guard !Task.isCancelled else { return }
            loadedImage = image
        }
    }
}
