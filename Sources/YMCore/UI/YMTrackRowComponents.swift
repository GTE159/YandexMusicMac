import SwiftUI
import AppKit

// MARK: - Isolated Like Heart Button

/// Isolated heart like button that subscribes to LikesService without re-rendering parent track rows.
public struct YMLikeHeartButton: View {
    public let track: YMTrack
    public var iconSize: CGFloat = 13
    public var buttonWidth: CGFloat = 32

    @UIState private var likesService = LikesService.shared
    @UIState private var isHovered = false

    public init(track: YMTrack, iconSize: CGFloat = 13, buttonWidth: CGFloat = 32) {
        self.track = track
        self.iconSize = iconSize
        self.buttonWidth = buttonWidth
    }

    public var body: some View {
        let isLiked = likesService.isLiked(trackId: track.id)
        Button {
            Task { await likesService.toggleLike(track: track) }
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: iconSize, weight: isLiked ? .semibold : .regular))
                .foregroundStyle(isLiked ? YMTheme.heartRed : (isHovered ? YMTheme.fg80 : YMTheme.fg40))
                .scaleEffect(isHovered ? 1.12 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isHovered)
                .animation(.spring(response: 0.24, dampingFraction: 0.65), value: isLiked)
        }
        .buttonStyle(.plain)
        .frame(width: buttonWidth, height: 28, alignment: .center)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside && TrackHoverManager.shared.isScrollSuppressed { return }
            if isHovered != inside { isHovered = inside }
        }
        .onDisappear {
            if isHovered { isHovered = false }
        }
        .help(isLiked ? "Удалить из Мне нравится" : "Мне нравится")
    }
}

// MARK: - Isolated Like Context Menu Item

/// Context menu item isolating LikesService subscription
public struct LikeContextMenuItem: View {
    public let track: YMTrack
    @UIState private var likesService = LikesService.shared

    public init(track: YMTrack) {
        self.track = track
    }

    public var body: some View {
        let isLiked = likesService.isLiked(trackId: track.id)
        Button(isLiked ? "Удалить из Мне нравится" : "Добавить в Мне нравится") {
            Task {
                await likesService.toggleLike(track: track)
            }
        }
    }
}

// MARK: - Hover Link Text

/// Lightweight clickable text with hover underline and color transition.
public struct YMHoverLinkText: View {
    public let text: String
    public var font: Font = .system(size: 12)
    public var baseColor: Color = YMTheme.fg60
    public var hoverColor: Color = YMTheme.fg
    public let action: () -> Void

    @UIState private var isHovered = false

    public init(
        text: String,
        font: Font = .system(size: 12),
        baseColor: Color = YMTheme.fg60,
        hoverColor: Color = YMTheme.fg,
        action: @escaping () -> Void
    ) {
        self.text = text
        self.font = font
        self.baseColor = baseColor
        self.hoverColor = hoverColor
        self.action = action
    }

    public var body: some View {
        Button {
            action()
        } label: {
            Text(text)
                .font(font)
                .foregroundStyle(isHovered ? hoverColor : baseColor)
                .underline(isHovered)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside && TrackHoverManager.shared.isScrollSuppressed { return }
            if isHovered != inside { isHovered = inside }
        }
        .onDisappear {
            if isHovered { isHovered = false }
        }
    }
}

// MARK: - Isolated Offline Track Badge

/// Isolated offline status badge subscribing only to the per-track `TrackOfflineState` for `trackId`.
/// Produces zero parent row invalidations during downloads.
public struct YMTrackOfflineBadge: View {
    public let trackId: String
    @UIState private var offlineManager = OfflineDownloadManager.shared

    public init(trackId: String) {
        self.trackId = trackId
    }

    public var body: some View {
        let phase = offlineManager.state(for: trackId).phase
        switch phase {
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(YMTheme.accent.opacity(0.85))
                .frame(width: 14, height: 14)
                .help("Доступно оффлайн")
        case .queued:
            Button {
                offlineManager.cancelDownload(trackId: trackId)
            } label: {
                Image(systemName: "clock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(YMTheme.fg40)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("В очереди на скачивание — нажмите для отмены")
        case .downloading(let progress):
            Button {
                offlineManager.cancelDownload(trackId: trackId)
            } label: {
                ZStack {
                    Circle()
                        .stroke(YMTheme.surfaceComponentHover, lineWidth: 1.6)
                    Circle()
                        .trim(from: 0, to: max(0.06, min(1.0, progress)))
                        .stroke(YMTheme.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                .padding(1)
            }
            .buttonStyle(.plain)
            .help("Скачивание \(Int(progress * 100))% — нажмите для отмены")
        case .encrypting:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.65)
                .frame(width: 14, height: 14)
                .help("Шифрование оффлайн-трека...")
        case .notDownloaded, .failed:
            EmptyView()
        }
    }
}

// MARK: - Isolated Offline Context Menu Item

/// Context menu action isolating `OfflineDownloadManager` subscription for a single track.
public struct OfflineDownloadContextMenuItem: View {
    public let track: YMTrack
    @UIState private var offlineManager = OfflineDownloadManager.shared

    public init(track: YMTrack) {
        self.track = track
    }

    public var body: some View {
        let phase = offlineManager.state(for: track.id).phase
        switch phase {
        case .notDownloaded, .failed:
            Button("Скачать для оффлайна") {
                offlineManager.enqueueDownload(track: track)
            }
        case .queued, .downloading, .encrypting:
            Button("Отменить скачивание") {
                offlineManager.cancelDownload(trackId: track.id)
            }
        case .downloaded:
            Button("Удалить из скачанного", role: .destructive) {
                Task {
                    await offlineManager.deleteDownload(trackId: track.id)
                }
            }
        }
    }
}

// MARK: - Isolated Batch Download Button

/// Isolated action button for downloading an entire album or playlist without re-rendering the parent screen.
public struct BatchDownloadButton: View {
    public let tracks: [YMTrack]
    public var height: CGFloat = 34
    public var compact: Bool = false

    @UIState private var offlineManager = OfflineDownloadManager.shared

    public init(tracks: [YMTrack], height: CGFloat = 34, compact: Bool = false) {
        self.tracks = tracks
        self.height = height
        self.compact = compact
    }

    public var body: some View {
        let playable = tracks.filter { !$0.isPlaceholder && !$0.isSpacer }
        let downloadedIds = offlineManager.downloadedTrackIds
        let downloadedCount = playable.reduce(0) { count, track in
            count + (downloadedIds.contains(OfflineTrackID.clean(track.id)) ? 1 : 0)
        }
        let allDownloaded = !playable.isEmpty && downloadedCount == playable.count
        let activeTracks = playable.filter { offlineManager.state(for: $0.id).phase.isActive }
        let isDownloadingAny = !activeTracks.isEmpty

        Button {
            if allDownloaded {
                return
            } else if isDownloadingAny {
                for track in activeTracks {
                    offlineManager.cancelDownload(trackId: track.id)
                }
            } else {
                offlineManager.enqueueDownloads(tracks: playable)
            }
        } label: {
            if allDownloaded {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(YMTheme.accent)
                    Text(compact ? "Оффлайн" : "Скачано")
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else if isDownloadingAny {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.78)
                    Text(compact ? "\(downloadedCount)/\(playable.count)" : "Скачивание (\(downloadedCount)/\(playable.count))")
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                Label("Скачать", systemImage: "arrow.down.circle")
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: false, height: height))
        .disabled(playable.isEmpty || allDownloaded)
        .help(
            allDownloaded
                ? "Все треки скачаны для оффлайн-прослушивания"
                : (isDownloadingAny ? "Нажмите для отмены скачивания" : "Скачать все треки для прослушивания без интернета")
        )
    }
}
