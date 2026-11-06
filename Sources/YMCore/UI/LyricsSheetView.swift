import SwiftUI

/// Elegant Lyrics sheet/panel displaying song lyrics with smooth scrolling and high contrast typography.
public struct LyricsSheetView: View {
    public let track: YMTrack?
    @Environment(\.dismiss) private var dismiss

    @UIState private var supplement: YMTrackSupplement? = nil
    @UIState private var isLoading = true
    @UIState private var errorMessage: String? = nil

    private let networkClient = YMNetworkClient.shared

    public init(track: YMTrack?) {
        self.track = track
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 14) {
                if let track = track {
                    CachedCoverImage(
                        coverUri: track.effectiveCoverUri,
                        size: .small,
                        displaySize: 44,
                        cornerRadius: 6
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.displayTitle)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(YMTheme.fg)
                            .lineLimit(1)

                        Text(track.artistsString)
                            .font(.caption)
                            .foregroundStyle(YMTheme.fg60)
                            .lineLimit(1)
                    }
                } else {
                    Text("Текст песни")
                        .font(.headline)
                        .foregroundStyle(YMTheme.fg)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(YMTheme.fg40)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(YMTheme.surface)

            Divider()

            // Lyrics Body
            if isLoading {
                VStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Загрузка текста песни...")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 36))
                        .foregroundStyle(YMTheme.fg40)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics = supplement?.lyrics, !lyrics.displayText.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(lyrics.displayText)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(YMTheme.fg)
                            .lineSpacing(8)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(32)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 36))
                        .foregroundStyle(YMTheme.fg40)
                    Text("К сожалению, текст для этого трека пока не добавлен в Яндекс Музыку.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 460, idealHeight: 560)
        .ymScreenBackground()
        .task {
            loadLyrics()
        }
    }

    private func loadLyrics() {
        guard let track = track else {
            isLoading = false
            errorMessage = "Сейчас ничего не воспроизводится."
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let supp = try await networkClient.fetchTrackSupplement(trackId: track.id)
                await MainActor.run {
                    self.supplement = supp
                    self.isLoading = false
                    if supp.lyrics == nil {
                        self.errorMessage = "Текст для этого трека отсутствует."
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = "Не удалось загрузить слова: \(error.localizedDescription)"
                }
            }
        }
    }
}
