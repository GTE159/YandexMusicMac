import SwiftUI

/// Native macOS Album detail view showing album cover, artist link, metadata, and full tracklist.
public struct AlbumDetailView: View {
    public let albumId: String
    public let albumTitle: String

    @UIState private var album: YMAlbumWithTracks? = nil
    @UIState private var isLoading = true
    @UIState private var errorMessage: String? = nil

    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    private let networkClient = YMNetworkClient.shared

    public init(albumId: String, albumTitle: String) {
        self.albumId = albumId
        self.albumTitle = albumTitle
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Navigation Bar
            HStack(spacing: 12) {
                Button {
                    coordinator.pop()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Назад")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(YMTheme.surfaceComponent))
                    .overlay(Capsule().strokeBorder(YMTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)

                Text(albumTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(YMTheme.fg60)

                Spacer()
            }
            .padding(.top, 16)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Загрузка альбома...")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Повторить") {
                        loadAlbumData()
                    }
                    .buttonStyle(YMGlassPillButtonStyle(primary: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let album = album {
                // Hero Header
                HStack(alignment: .bottom, spacing: 24) {
                    CachedCoverImage(
                        coverUri: album.coverUri,
                        size: .large,
                        displaySize: 160,
                        cornerRadius: YMTheme.cornerRadiusMedium
                    )
                    .frame(width: 160, height: 160)
                    .shadow(color: .black.opacity(0.45), radius: 20, y: 10)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("АЛЬБОМ")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(YMTheme.fg40)
                            .tracking(1.2)

                        Text(album.title)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(YMTheme.fg)
                            .lineLimit(2)

                        // Artists row (clickable)
                        HStack(spacing: 6) {
                            ForEach(album.artists) { artist in
                                Button {
                                    coordinator.navigate(to: .artist(id: artist.id, name: artist.name))
                                } label: {
                                    Text(artist.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(YMTheme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Text(album.formattedInfo)
                            .font(.caption)
                            .foregroundStyle(YMTheme.fg60)

                        // Action Bar
                        HStack(spacing: 12) {
                            Button {
                                audioEngine.assignQueue(album.allTracks, startingAt: 0)
                            } label: {
                                Label("Слушать альбом", systemImage: "play.fill")
                            }
                            .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 34))
                        }
                        .padding(.top, 4)
                    }

                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

                Divider()
                    .padding(.horizontal, 24)

                // Tracklist Table
                TrackTableView(
                    tracks: album.allTracks,
                    onPlayTrack: { selectedTrack in
                        if let index = album.allTracks.firstIndex(where: { $0.id == selectedTrack.id }) {
                            audioEngine.assignQueue(album.allTracks, startingAt: index)
                        } else {
                            audioEngine.assignQueue([selectedTrack], startingAt: 0)
                        }
                    }
                )
                .padding(.horizontal, 16)
            }
        }
        .ymScreenBackground()
        .task {
            loadAlbumData()
        }
    }

    private func loadAlbumData() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let fetched = try await networkClient.fetchAlbumWithTracks(albumId: albumId)
                await MainActor.run {
                    self.album = fetched
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Не удалось загрузить альбом: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
}
