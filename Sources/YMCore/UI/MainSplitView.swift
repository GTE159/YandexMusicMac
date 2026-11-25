import SwiftUI

public enum SidebarSection: String, CaseIterable, Identifiable {
    case myWave = "Моя волна"
    case chart = "Чарт"
    case favorites = "Мне нравится"
    case playlists = "Плейлисты"
    case downloads = "Скачанное"
    case search = "Поиск"
    case settings = "Настройки"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .myWave: return "waveform.path.ecg"
        case .chart: return "chart.line.uptrend.xyaxis"
        case .favorites: return "heart.fill"
        case .playlists: return "music.note.list"
        case .downloads: return "arrow.down.circle.fill"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

/// Main macOS NavigationSplitView orchestrating the sidebar, NavigationStack, and the Player Bar.
public struct MainSplitView: View {
    @UIState private var coordinator = NavigationCoordinator.shared
    @UIState private var authService = AuthService.shared
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var rotorService = RotorService.shared
    @UIState private var playlistsService = PlaylistsService.shared
    @UIState private var windowState = WindowState.shared
    @UIState private var themeManager = YMThemeManager.shared
    @UIState private var columnVisibility: NavigationSplitViewVisibility = .all
    @UIState private var keyEventMonitor: Any? = nil

    public init() {}

    private var selectedSection: SidebarSection {
        coordinator.selectedSection
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 216, ideal: 236, max: 290)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(themeManager.currentTheme.colorScheme)
        .frame(minWidth: 440, minHeight: 320)
        .sheet(isPresented: $audioEngine.isSubscriptionRequiredPresented) {
            SubscriptionRequiredSheetView(isPresented: $audioEngine.isSubscriptionRequiredPresented)
        }
        .sheet(isPresented: $playlistsService.isQuickCreateSheetPresented) {
            PlaylistEditorSheet(
                editingPlaylist: nil,
                initialTracks: playlistsService.pendingInitialTrack.map { [$0] } ?? [],
                onDismiss: {
                    playlistsService.isQuickCreateSheetPresented = false
                    playlistsService.pendingInitialTrack = nil
                },
                onSaved: { _ in
                    playlistsService.isQuickCreateSheetPresented = false
                    playlistsService.pendingInitialTrack = nil
                }
            )
        }
        .ymTouchBar()
        .onAppear {
            windowState.isSidebarVisible = (columnVisibility != .detailOnly)
            setupRotorAudioHooks()
            themeManager.updateWindowAppearance()
            setupKeyboardMonitor()
            Task {
                await playlistsService.ensureLoaded()
                await OfflineDownloadManager.shared.loadIndexIfNeeded()
            }
        }
        .onDisappear {
            if let monitor = keyEventMonitor {
                NSEvent.removeMonitor(monitor)
                keyEventMonitor = nil
            }
        }
        .onChange(of: columnVisibility) { _, newVisibility in
            windowState.isSidebarVisible = (newVisibility != .detailOnly)
        }
        .onChange(of: windowState.isCompactWidth) { _, isCompact in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                columnVisibility = isCompact ? .detailOnly : .all
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fixed top spacing with native macOS window drag handle below traffic lights
            YMWindowDragHandle()
                .frame(height: 52)

            VStack(alignment: .leading, spacing: 18) {
                // Section 1: Медиатека
                VStack(alignment: .leading, spacing: 3) {
                    Text("Медиатека")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(YMTheme.fg40)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)

                    sidebarButton(section: .myWave)

                    sidebarButton(
                        section: .chart,
                        badge: "ТОП-100",
                        badgeColor: YMTheme.accent
                    )

                    sidebarButton(section: .favorites)

                    sidebarButton(section: .playlists)

                    sidebarButton(section: .downloads)
                }

                // Section 2: Обзор и настройки
                VStack(alignment: .leading, spacing: 3) {
                    Text("Обзор и настройки")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(YMTheme.fg40)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)

                    sidebarButton(section: .search)
                    sidebarButton(section: .settings)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            // User account card in sidebar footer
            if let user = authService.currentUser {
                Divider()
                    .overlay(YMTheme.border)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        ZStack {
                            Circle()
                                .fill(YMTheme.surfaceHigh)
                                .frame(width: 34, height: 34)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            user.hasActiveSubscription
                                                ? YMTheme.accent.opacity(0.75)
                                                : YMTheme.border,
                                            lineWidth: user.hasActiveSubscription ? 1.5 : 1
                                        )
                                )

                            Image(systemName: "person.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(YMTheme.accent)
                        }

                        if user.hasActiveSubscription {
                            ZStack {
                                Circle()
                                    .fill(YMTheme.accentFill)
                                    .frame(width: 14, height: 14)

                                Image(systemName: "sparkles")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Color.black)
                            }
                            .offset(x: 2, y: 2)
                        }
                    }
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(YMTheme.fg)
                            .lineLimit(1)

                        if user.hasActiveSubscription {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 3) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 8))
                                    Text("Яндекс Плюс")
                                        .font(.system(size: 10, weight: .semibold))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }

                                Text("Плюс")
                                    .font(.system(size: 10, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(YMTheme.accent)
                        } else {
                            Text("Без Плюса")
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(YMTheme.fg40)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        authService.signOut()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(YMTheme.fg60)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(YMTheme.surfaceComponent))
                    }
                    .buttonStyle(.plain)
                    .help("Выйти из аккаунта")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(YMTheme.surfaceComponent)
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .help(user.hasActiveSubscription ? "Подписка Яндекс Плюс активна" : "Подписка Яндекс Плюс не активна")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                VisualEffectBlur(material: .sidebar, blendingMode: .behindWindow)
                YMTheme.sidebarBg.opacity(0.78)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            YMTheme.border
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func sidebarButton(
        section: SidebarSection,
        badge: String? = nil,
        badgeColor: Color = YMTheme.fg60
    ) -> some View {
        let isSelected = selectedSection == section

        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                coordinator.selectSection(section)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.iconName)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(
                        isSelected ? YMTheme.accent :
                        (section == .favorites ? YMTheme.heartRed : YMTheme.fg60)
                    )
                    .frame(width: 20, alignment: .center)

                Text(section.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? YMTheme.fg : YMTheme.fg80)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                if section == .favorites {
                    SidebarFavoritesBadge()
                } else if section == .downloads {
                    SidebarDownloadsBadge()
                } else if let badge = badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(badgeColor == YMTheme.accent ? YMTheme.accent.opacity(0.18) : YMTheme.surfaceComponent)
                        )
                        .foregroundStyle(badgeColor)
                        .layoutPriority(2)
                }
            }
            .padding(.leading, 11)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(YMTheme.surfaceComponentHover)
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(YMTheme.accent.opacity(0.10))
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(YMTheme.border, lineWidth: 1)
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        ZStack(alignment: .bottom) {
            // Main Navigation Content (with dynamic bottom inset for docked bottom bars)
            ZStack(alignment: .topLeading) {
                    // Custom zero-chrome route stack avoids macOS NavigationStack's ghost titlebar safe-area inset
                    // and preserves underlying section state (e.g., search query & scroll position) on back navigation.
                    ZStack {
                        Group {
                            switch selectedSection {
                            case .myWave:
                                MyWaveView()
                            case .chart:
                                ChartView()
                            case .favorites:
                                FavoritesListView()
                            case .playlists:
                                PlaylistsView()
                            case .downloads:
                                DownloadsView()
                            case .search:
                                SearchView()
                            case .settings:
                                SettingsView()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(coordinator.path.isEmpty)
                        .accessibilityHidden(!coordinator.path.isEmpty)

                        if let activeRoute = coordinator.path.last {
                            Group {
                                switch activeRoute {
                                case .artist(let id, let name):
                                    ArtistDetailView(artistId: id, artistName: name)
                                        .id("artist_\(id)")
                                case .album(let id, let title):
                                    AlbumDetailView(albumId: id, albumTitle: title)
                                        .id("album_\(id)")
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(YMTheme.bg.ignoresSafeArea())
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.16), value: coordinator.path)

                    // Sidebar Toggle Button: always visible whenever in compact window OR whenever sidebar is collapsed
                    if windowState.isCompactWidth || columnVisibility == .detailOnly {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
                            }
                        } label: {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(YMTheme.fg80)
                                .padding(8)
                                .background(
                                    Circle()
                                        .fill(.ultraThinMaterial)
                                        .overlay(Circle().strokeBorder(YMTheme.border, lineWidth: 1))
                                        .shadow(color: YMTheme.shadowColor, radius: 6, y: 2)
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, (windowState.isFullScreen || columnVisibility != .detailOnly) ? 16 : 84)
                        .padding(.top, windowState.isFullScreen ? 14 : 10)
                        .help("Показать/скрыть боковое меню")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom) {
                let isAbovePlayer = coordinator.isLyricsPresented && coordinator.lyricsPosition == .abovePlayer
                Color.clear.frame(height: 76 + (isAbovePlayer ? 74 : 0))
            }

            // Fullscreen "Now Playing" Lyrics overlay spanning full detail area so its blurred cover
            // backdrop extends seamlessly behind PlayerBarView (content itself reserves 76pt at bottom).
            if coordinator.isLyricsPresented && coordinator.lyricsPosition == .right {
                LyricsSheetView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            // Bottom Stack: Toast + AbovePlayerLyricsBar (if active) + PlayerBarView
            VStack(spacing: 0) {
                if let toast = playlistsService.toastMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(YMTheme.accent)
                        Text(toast)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(YMTheme.fg)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(YMTheme.surfaceHigh)
                            .overlay(Capsule(style: .continuous).strokeBorder(YMTheme.borderHover, lineWidth: 1))
                            .shadow(color: YMTheme.shadowColor, radius: 10, y: 4)
                    )
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if coordinator.isLyricsPresented && coordinator.lyricsPosition == .abovePlayer {
                    AbovePlayerLyricsBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                PlayerBarView()
            }
            .animation(.easeOut(duration: 0.20), value: playlistsService.toastMessage)

            // Custom Floating Equalizer Card (smooth GPU spring animation inside window)
            if coordinator.isEqualizerPresented {
                let isAbovePlayer = coordinator.isLyricsPresented && coordinator.lyricsPosition == .abovePlayer
                let bottomOffset: CGFloat = 76 + (isAbovePlayer ? 74 : 0) + 10

                ZStack(alignment: .bottomTrailing) {
                    // Невидимая подложка для закрытия по клику вне карточки
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                                coordinator.isEqualizerPresented = false
                            }
                        }

                    EqualizerPopoverView()
                        .padding(.trailing, windowState.isCompactWidth ? 12 : 20)
                        .padding(.bottom, bottomOffset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(
                    .asymmetric(
                        insertion: .opacity
                            .combined(with: .scale(scale: 0.92, anchor: .bottomTrailing))
                            .combined(with: .offset(y: 8)),
                        removal: .opacity
                            .combined(with: .scale(scale: 0.95, anchor: .bottomTrailing))
                    )
                )
                .zIndex(20)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle("")
        .background(YMTheme.bg.ignoresSafeArea())
    }

    private func setupRotorAudioHooks() {
        // Connect AudioPlayerEngine events with RotorService telemetry
        audioEngine.onTrackStarted = { track in
            Task {
                try? await rotorService.sendTrackStarted(track: track)
            }
        }

        audioEngine.onTrackFinished = { track, totalSeconds in
            Task {
                try? await rotorService.sendTrackFinished(track: track, totalPlayedSeconds: totalSeconds)
            }
        }

        audioEngine.onTrackSkipped = { track, playedSeconds in
            Task {
                try? await rotorService.sendTrackSkipped(track: track, playedSeconds: playedSeconds)
            }
        }
    }

    private func setupKeyboardMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let keyWindow = NSApp.keyWindow, WindowState.shared.isValidAppWindow(keyWindow) else {
                    return false
                }
                // If the user is currently editing text in a search field or text view, preserve native cursor navigation
                if let responder = keyWindow.firstResponder,
                   responder is NSTextView || responder is NSText {
                    return false
                }

                if flags.isEmpty && keyCode == 53 && NavigationCoordinator.shared.isEqualizerPresented {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                        NavigationCoordinator.shared.isEqualizerPresented = false
                    }
                    return true
                }
                // Bare Left Arrow (123) and Right Arrow (124) without Command/Option/Control
                if flags.isEmpty {
                    if keyCode == 123 { // Left Arrow
                        audioEngine.seekRelative(by: -5.0)
                        return true
                    } else if keyCode == 124 { // Right Arrow
                        audioEngine.seekRelative(by: 5.0)
                        return true
                    }
                }
                return false
            }
            return handled ? nil : event
        }
    }
}

// MARK: - Isolated Sidebar Favorites Badge

private struct SidebarFavoritesBadge: View {
    @UIState private var likesService = LikesService.shared

    var body: some View {
        let count = likesService.likedTrackIds.count
        if count > 0 {
            Text(formatLikedCount(count))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(YMTheme.surfaceComponent)
                )
                .foregroundStyle(YMTheme.fg60)
                .layoutPriority(2)
        }
    }

    private func formatLikedCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%d\u{00A0}%03d\u{00A0}%03d", count / 1_000_000, (count / 1000) % 1000, count % 1000)
        } else if count >= 1000 {
            return String(format: "%d\u{00A0}%03d", count / 1000, count % 1000)
        } else {
            return "\(count)"
        }
    }
}

// MARK: - Isolated Sidebar Downloads Badge

private struct SidebarDownloadsBadge: View {
    @UIState private var offlineManager = OfflineDownloadManager.shared

    var body: some View {
        let count = offlineManager.downloadedTrackIds.count
        let active = offlineManager.activeDownloadsCount
        if active > 0 || count > 0 {
            HStack(spacing: 4) {
                if active > 0 {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 10, height: 10)
                }

                Text("\(active > 0 && count == 0 ? active : count)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(active > 0 ? YMTheme.accent.opacity(0.18) : YMTheme.surfaceComponent)
            )
            .foregroundStyle(active > 0 ? YMTheme.accent : YMTheme.fg60)
            .layoutPriority(2)
        }
    }
}
