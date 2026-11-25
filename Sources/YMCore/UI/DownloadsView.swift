import SwiftUI

/// Dedicated offline library section ("Скачанное") working 100% without internet access.
public struct DownloadsView: View {
    @UIState private var offlineManager = OfflineDownloadManager.shared
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var windowState = WindowState.shared

    @UIState private var filterQuery = ""
    @UIState private var isScrolled = false

    public init() {}

    private var allDownloadedTracks: [YMTrack] {
        offlineManager.downloadedTracks()
    }

    private var displayedTracks: [YMTrack] {
        let q = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return allDownloadedTracks
        }
        return allDownloadedTracks.filter { track in
            track.displayTitle.localizedCaseInsensitiveContains(q) ||
            track.artists.contains { $0.name.localizedCaseInsensitiveContains(q) } ||
            (track.artists.isEmpty && track.artistsString.localizedCaseInsensitiveContains(q)) ||
            (track.primaryAlbumTitle?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private func formatTrackCount(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod100 >= 11 && mod100 <= 19 {
            return "\(count) треков"
        }
        switch mod10 {
        case 1: return "\(count) трек"
        case 2, 3, 4: return "\(count) трека"
        default: return "\(count) треков"
        }
    }

    private func formattedByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 20) {
                // Hero Header
                let tileSize: CGFloat = windowState.isMiniWidth ? 80 : (windowState.isCompactWidth ? 96 : 120)
                let iconSize: CGFloat = windowState.isMiniWidth ? 34 : (windowState.isCompactWidth ? 42 : 50)
                HStack(alignment: .bottom, spacing: windowState.isCompactWidth ? 16 : 20) {
                    ZStack {
                        RoundedRectangle(cornerRadius: windowState.isMiniWidth ? 12 : 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 40 / 255, green: 158 / 255, blue: 126 / 255),
                                        Color(red: 26 / 255, green: 112 / 255, blue: 146 / 255),
                                        Color(red: 36 / 255, green: 62 / 255, blue: 112 / 255)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: tileSize, height: tileSize)
                            .overlay(
                                RoundedRectangle(cornerRadius: windowState.isMiniWidth ? 12 : 16, style: .continuous)
                                    .fill(
                                        RadialGradient(
                                            colors: [
                                                Color.white.opacity(0.24),
                                                Color.white.opacity(0.0)
                                            ],
                                            center: .topLeading,
                                            startRadius: 4,
                                            endRadius: tileSize * 0.8
                                        )
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: windowState.isMiniWidth ? 12 : 16, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            )
                            .shadow(color: Color(red: 26 / 255, green: 112 / 255, blue: 146 / 255).opacity(0.28), radius: 18, y: 8)

                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: iconSize, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.24), radius: 6, y: 3)
                    }

                    VStack(alignment: .leading, spacing: windowState.isCompactWidth ? 6 : 8) {
                        Text("ОФФЛАЙН МЕДИАТЕКА")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(YMTheme.fg40)
                            .tracking(1.2)

                        Text("Скачанное")
                            .font(.system(size: windowState.isCompactWidth ? 22 : 28, weight: .bold))
                            .foregroundStyle(YMTheme.fg)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(formatTrackCount(offlineManager.downloadedRecords.count))
                            if offlineManager.totalUsedBytes > 0 {
                                Text("• \(formattedByteCount(offlineManager.totalUsedBytes))")
                            }
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(YMTheme.fg60)
                        .lineLimit(1)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                playAllButton(title: "Слушать всё", height: 32)
                                shuffleButton(title: "Перемешать", height: 32)
                            }

                            HStack(spacing: 8) {
                                playAllButton(title: "Слушать", height: 30)
                                shuffleButton(title: "Микс", height: 30)
                            }
                        }
                        .padding(.top, 2)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, windowState.isMiniWidth ? 16 : 24)
                .padding(.top, windowState.topChromeContentPadding)

                // Active downloads card
                if offlineManager.activeDownloadsCount > 0 || offlineManager.pendingDownloadsCount > 0 {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)

                        VStack(alignment: .leading, spacing: 2) {
                            let activeCount = offlineManager.activeDownloadsCount
                            let pendingCount = offlineManager.pendingDownloadsCount
                            Text("Загрузка треков для оффлайн-доступа: \(activeCount)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(YMTheme.fg)

                            if pendingCount > 0 {
                                Text("Ещё в очереди: \(pendingCount)")
                                    .font(.caption)
                                    .foregroundStyle(YMTheme.fg60)
                            }
                        }

                        Spacer()

                        Button("Отменить все") {
                            offlineManager.cancelAllDownloads()
                        }
                        .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 28))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(YMTheme.surfaceComponent)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(YMTheme.accent.opacity(0.30), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, windowState.isMiniWidth ? 16 : 24)
                }

                // Last error banner
                if let errorMessage = offlineManager.lastErrorMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(YMTheme.fg80)
                            .lineLimit(2)

                        Spacer()

                        Button {
                            offlineManager.dismissError()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(YMTheme.fg40)
                        }
                        .buttonStyle(.plain)
                        .help("Скрыть уведомление")
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.orange.opacity(0.10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.orange.opacity(0.28), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, windowState.isMiniWidth ? 16 : 24)
                }

                // Filter bar
                if !allDownloadedTracks.isEmpty || !filterQuery.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(YMTheme.fg40)

                        TextField("Поиск по скачанным трекам, артистам и альбомам...", text: $filterQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))

                        if !filterQuery.isEmpty {
                            Text("\(displayedTracks.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(YMTheme.fg40)

                            Button {
                                filterQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(YMTheme.fg40)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(YMTheme.surfaceComponent)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(YMTheme.border, lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 24)
                }

                // Content
                if allDownloadedTracks.isEmpty && offlineManager.activeDownloadsCount == 0 {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 44))
                            .foregroundStyle(YMTheme.fg40)

                        Text("Здесь появятся треки для прослушивания без интернета")
                            .font(.headline)
                            .foregroundStyle(YMTheme.fg)
                            .multilineTextAlignment(.center)

                        Text("Нажмите правой кнопкой на любой трек или откройте альбом/плейлист и выберите «Скачать»")
                            .font(.subheadline)
                            .foregroundStyle(YMTheme.fg60)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else if displayedTracks.isEmpty && !filterQuery.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 36))
                            .foregroundStyle(YMTheme.fg40)
                        Text("Ничего не найдено")
                            .font(.headline)
                            .foregroundStyle(YMTheme.fg)
                        Text("По запросу «\(filterQuery)» среди скачанных треков ничего не найдено")
                            .font(.subheadline)
                            .foregroundStyle(YMTheme.fg60)
                            .multilineTextAlignment(.center)
                        Button("Очистить поиск") {
                            filterQuery = ""
                        }
                        .buttonStyle(YMGlassPillButtonStyle(primary: false))
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if !displayedTracks.isEmpty {
                    TrackTableView(
                        tracks: displayedTracks,
                        onPlayTrack: { track in
                            audioEngine.isWaveMode = false
                            if let index = displayedTracks.firstIndex(where: { $0.id == track.id }) {
                                audioEngine.setQueue(displayedTracks, startingAt: index)
                            } else {
                                audioEngine.setQueue([track], startingAt: 0)
                            }
                        }
                    )
                    .padding(.horizontal, 14)
                }
            }
            .padding(.bottom, 80)
            .background(alignment: .top) {
                if #unavailable(macOS 15.0) {
                    YMScrollTopSentinel(
                        coordinateSpaceName: "downloads_scroll",
                        threshold: 88,
                        isScrolled: $isScrolled
                    )
                }
            }
        }
        .ymTrackScrollOffset(threshold: 88, isScrolled: $isScrolled)
        .coordinateSpace(name: "downloads_scroll")
        .overlay(alignment: .top) {
            YMStickyTopBar(title: "Скачанное", isVisible: isScrolled)
        }
        .ymScreenBackground()
        .task {
            await offlineManager.loadIndexIfNeeded()
        }
    }

    @ViewBuilder
    private func playAllButton(title: String, height: CGFloat) -> some View {
        Button {
            guard !displayedTracks.isEmpty else { return }
            audioEngine.isWaveMode = false
            audioEngine.setQueue(displayedTracks, startingAt: 0)
        } label: {
            Label(title, systemImage: "play.fill")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: true, height: height))
        .disabled(displayedTracks.isEmpty)
    }

    @ViewBuilder
    private func shuffleButton(title: String, height: CGFloat) -> some View {
        Button {
            audioEngine.playShuffled(displayedTracks)
        } label: {
            Label(title, systemImage: "shuffle")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: false, height: height))
        .disabled(displayedTracks.isEmpty)
    }
}
