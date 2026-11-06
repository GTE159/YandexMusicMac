import SwiftUI

public enum SidebarSection: String, CaseIterable, Identifiable {
    case myWave = "Моя волна"
    case chart = "Чарт"
    case favorites = "Мне нравится"
    case playlists = "Плейлисты"
    case search = "Поиск"
    case settings = "Настройки"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .myWave: return "waveform.path.ecg"
        case .chart: return "chart.line.uptrend.xyaxis"
        case .favorites: return "heart.fill"
        case .playlists: return "music.note.list"
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
    @UIState private var likesService = LikesService.shared
    @UIState private var windowState = WindowState.shared
    @UIState private var themeManager = YMThemeManager.shared
    @UIState private var columnVisibility: NavigationSplitViewVisibility = .all

    public init() {}

    private var selectedSection: SidebarSection {
        coordinator.selectedSection
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            detailContent
        }
        .preferredColorScheme(themeManager.currentTheme.colorScheme)
        .toolbar(.hidden, for: .windowToolbar)
        .frame(minWidth: 440, minHeight: 320)
        .ymTouchBar()
        .onAppear {
            setupRotorAudioHooks()
            themeManager.updateWindowAppearance()
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fixed top spacing to keep sidebar items cleanly below window controls
            Color.clear
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

                    sidebarButton(
                        section: .favorites,
                        badge: likesService.likedTrackIds.isEmpty ? nil : formatLikedCount(likesService.likedTrackIds.count),
                        badgeColor: YMTheme.fg60
                    )

                    sidebarButton(section: .playlists)
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
                    ZStack {
                        Circle()
                            .fill(YMTheme.surfaceHigh)
                            .frame(width: 34, height: 34)
                            .overlay(Circle().strokeBorder(YMTheme.border, lineWidth: 1))

                        Image(systemName: "person.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(YMTheme.accent)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(YMTheme.fg)
                            .lineLimit(1)

                        if user.hasActiveSubscription {
                            HStack(spacing: 3) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 8))
                                Text("Плюс активен")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundColor(YMTheme.accent)
                        }
                    }

                    Spacer()

                    Button {
                        authService.signOut()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 13))
                            .foregroundStyle(YMTheme.fg40)
                            .padding(6)
                            .background(Circle().fill(YMTheme.surfaceComponent))
                    }
                    .buttonStyle(.plain)
                    .help("Выйти из аккаунта")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(YMTheme.surface.opacity(0.6))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(YMTheme.border, lineWidth: 1))
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(YMTheme.sidebarBg.ignoresSafeArea())
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
            coordinator.selectSection(section)
        } label: {
            HStack(spacing: 10) {
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

                Spacer(minLength: 6)

                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(badgeColor == YMTheme.accent ? YMTheme.accent.opacity(0.18) : YMTheme.surfaceComponent)
                        )
                        .foregroundStyle(badgeColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? YMTheme.surfaceComponentHover : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? YMTheme.border : Color.clear, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatLikedCount(_ count: Int) -> String {
        if count >= 1000 {
            return "\(count / 1000) \(count % 1000)"
        }
        return "\(count)"
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .topLeading) {
                NavigationStack(path: $coordinator.path) {
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
                        case .search:
                            SearchView()
                        case .settings:
                            SettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .artist(let id, let name):
                            ArtistDetailView(artistId: id, artistName: name)
                        case .album(let id, let title):
                            AlbumDetailView(albumId: id, albumTitle: title)
                        }
                    }
                }

                // Compact/Mini Window Sidebar Toggle Button
                if windowState.isCompactWidth {
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
                                    .fill(YMTheme.surface)
                                    .shadow(color: Color.black.opacity(0.3), radius: 6, y: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 16)
                    .padding(.top, 16)
                    .help("Показать/скрыть боковое меню")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 76)
            }

            PlayerBarView()
        }
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle("")
        .toolbar(.hidden, for: .windowToolbar)
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
}
