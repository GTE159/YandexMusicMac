import SwiftUI

/// Native macOS Album detail view showing album cover, artist link, metadata, and full tracklist.
public struct AlbumDetailView: View {
    public let albumId: String
    public let albumTitle: String

    @UIState private var album: YMAlbumWithTracks? = nil
    @UIState private var cachedAllTracks: [YMTrack] = []
    @UIState private var isLoading = true
    @UIState private var errorMessage: String? = nil
    @UIState private var loadTask: Task<Void, Never>? = nil
    @UIState private var isScrolled = false

    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    @UIState private var windowState = WindowState.shared
    private let networkClient = YMNetworkClient.shared

    public init(albumId: String, albumTitle: String) {
        self.albumId = albumId
        self.albumTitle = albumTitle
    }

    public var body: some View {
        Group {
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
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Hero Header with atmospheric cover glow
                        let coverSize: CGFloat = windowState.isCompactWidth ? 104 : 160
                        HStack(alignment: .bottom, spacing: windowState.isCompactWidth ? 16 : 24) {
                            CachedCoverImage(
                                coverUri: album.coverUri,
                                size: .large,
                                displaySize: coverSize,
                                cornerRadius: YMTheme.cornerRadiusLarge
                            )
                            .frame(width: coverSize, height: coverSize)
                            .shadow(color: YMTheme.shadowColor, radius: 20, y: 10)

                            VStack(alignment: .leading, spacing: windowState.isCompactWidth ? 6 : 8) {
                                Text("АЛЬБОМ")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(YMTheme.fg40)
                                    .tracking(1.2)

                                Text(album.title)
                                    .font(.system(size: windowState.isCompactWidth ? 20 : 26, weight: .bold))
                                    .foregroundStyle(YMTheme.fg)
                                    .lineLimit(2)

                                // Artists row (clickable)
                                HStack(spacing: 6) {
                                    ForEach(album.artists) { artist in
                                        Button {
                                            coordinator.navigate(to: .artist(id: artist.id, name: artist.name))
                                        } label: {
                                            Text(artist.name)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(YMTheme.accent)
                                                .lineLimit(1)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                Text(album.formattedInfo)
                                    .font(.caption)
                                    .foregroundStyle(YMTheme.fg60)
                                    .lineLimit(1)

                                // Action Bar
                                HStack(spacing: 10) {
                                    Button {
                                        audioEngine.isWaveMode = false
                                        audioEngine.assignQueue(cachedAllTracks, startingAt: 0)
                                    } label: {
                                        Label(windowState.isMiniWidth ? "Слушать" : "Слушать альбом", systemImage: "play.fill")
                                    }
                                    .buttonStyle(YMGlassPillButtonStyle(primary: true, height: windowState.isMiniWidth ? 30 : 34))

                                    BatchDownloadButton(
                                        tracks: cachedAllTracks,
                                        height: windowState.isMiniWidth ? 30 : 34,
                                        compact: windowState.isMiniWidth
                                    )
                                }
                                .padding(.top, 4)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, windowState.isMiniWidth ? 16 : 24)
                        .padding(.top, 54)
                        .padding(.bottom, windowState.isCompactWidth ? 14 : 20)
                        .ymAmbientCoverGlow(coverUri: album.coverUri, opacity: 0.24)

                        Divider()
                            .overlay(YMTheme.border)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 8)

                        // Tracklist Table
                        TrackTableView(
                            tracks: cachedAllTracks,
                            onPlayTrack: { selectedTrack in
                                audioEngine.isWaveMode = false
                                if let index = cachedAllTracks.firstIndex(where: { $0.id == selectedTrack.id }) {
                                    audioEngine.assignQueue(cachedAllTracks, startingAt: index)
                                } else {
                                    audioEngine.assignQueue([selectedTrack], startingAt: 0)
                                }
                            }
                        )
                        .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 90)
                    .background(alignment: .top) {
                        if #unavailable(macOS 15.0) {
                            YMScrollTopSentinel(
                                coordinateSpaceName: "album_detail_scroll",
                                threshold: 84,
                                isScrolled: $isScrolled
                            )
                        }
                    }
                }
                .ymTrackScrollOffset(threshold: 84, isScrolled: $isScrolled)
                .coordinateSpace(name: "album_detail_scroll")
            }
        }
        .overlay(alignment: .top) {
            YMStickyDetailTopBar(
                backTitle: "Назад",
                title: album?.title ?? albumTitle,
                isScrolled: isScrolled
            ) {
                coordinator.pop()
            }
        }
        .ymScreenBackground()
        .task(id: albumId) {
            isScrolled = false
            loadAlbumData()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private func loadAlbumData() {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        let targetAlbumId = albumId
        loadTask = Task {
            do {
                let fetched = try await networkClient.fetchAlbumWithTracks(albumId: targetAlbumId)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.albumId == targetAlbumId else { return }
                    self.album = fetched
                    self.cachedAllTracks = fetched.allTracks
                    self.isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.albumId == targetAlbumId else { return }
                    self.errorMessage = "Не удалось загрузить альбом: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
}
