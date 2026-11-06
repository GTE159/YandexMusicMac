import SwiftUI
import AppKit
import YMCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Гарантируем, что приложение работает как полноценное GUI-приложение с иконкой в Dock
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        configureMainWindowIfNeeded()
    }

    /// Вызывается macOS при клике на иконку приложения в Dock
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        configureMainWindowIfNeeded()
    }

    private var isClosingFromFullScreen = false

    /// Перехватываем нажатие на красный крестик: для главного окна вместо уничтожения скрываем его в фон,
    /// чтобы музыка и состояние UI сохранялись, а клик по Dock мгновенно возвращал окно.
    /// В режиме Full Screen (Spaces) сначала плавно сворачиваем окно из пространства Spaces,
    /// чтобы не оставлять пустой чёрный рабочий стол.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === mainWindow {
            if sender.styleMask.contains(.fullScreen) {
                isClosingFromFullScreen = true
                sender.toggleFullScreen(nil)
                return false
            } else {
                sender.orderOut(nil)
                return false
            }
        }
        return true
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        WindowState.shared.isFullScreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        WindowState.shared.isFullScreen = false
        if isClosingFromFullScreen {
            isClosingFromFullScreen = false
            DispatchQueue.main.async { [weak self] in
                self?.mainWindow?.orderOut(nil)
            }
        }
    }

    func configureMainWindowIfNeeded() {
        for window in NSApp.windows where !(window is NSPanel) {
            // Игнорируем вспомогательное окно Settings (Cmd + ,)
            if window.identifier?.rawValue.contains("Settings") == true || window.title.contains("Settings") || window.title.contains("Настройки") {
                continue
            }
            if mainWindow == nil {
                mainWindow = window
            }
            guard window === mainWindow else { continue }

            if window.delegate !== self {
                window.delegate = self
            }
            window.title = ""
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 440, height: 320)
            window.toolbar = nil
            window.isMovableByWindowBackground = true
            YMThemeManager.shared.updateWindowAppearance()
            WindowState.shared.update(from: window)
        }
    }

    func showMainWindow() {
        configureMainWindowIfNeeded()
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct YandexMusicMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @UIState private var authService = AuthService.shared
    @UIState private var themeManager = YMThemeManager.shared

    init() {
        _ = RemoteCommandManager.shared
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authService.isAuthenticated {
                    MainSplitView()
                } else {
                    LoginView()
                }
            }
            .preferredColorScheme(themeManager.currentTheme.colorScheme)
            .tint(YMTheme.accent)
            .frame(minWidth: 440, minHeight: 320)
            .onAppear {
                appDelegate.configureMainWindowIfNeeded()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandMenu("Окно плеера") {
                Button("Показать главное окно") {
                    appDelegate.showMainWindow()
                }
                .keyboardShortcut("0", modifiers: [.command])
            }

            CommandMenu("Воспроизведение") {
                Button(AudioPlayerEngine.shared.isPlaying ? "Пауза" : "Воспроизведение") {
                    AudioPlayerEngine.shared.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Следующий трек") {
                    AudioPlayerEngine.shared.next()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Button("Предыдущий трек") {
                    AudioPlayerEngine.shared.previous()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Button("Вперед на 5 секунд") {
                    AudioPlayerEngine.shared.seekRelative(by: 5.0)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Button("Назад на 5 секунд") {
                    AudioPlayerEngine.shared.seekRelative(by: -5.0)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])

                Divider()

                Button("Увеличить громкость") {
                    AudioPlayerEngine.shared.volume = min(1.0, AudioPlayerEngine.shared.volume + 0.1)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])

                Button("Уменьшить громкость") {
                    AudioPlayerEngine.shared.volume = max(0.0, AudioPlayerEngine.shared.volume - 0.1)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])

                Button("Мне нравится / Удалить из избранного") {
                    if let track = AudioPlayerEngine.shared.currentTrack {
                        Task { await LikesService.shared.toggleLike(track: track) }
                    }
                }
                .keyboardShortcut("l", modifiers: [.command])

                Divider()

                Button("Перемешать очередь") {
                    AudioPlayerEngine.shared.toggleShuffle()
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Волна по текущему треку") {
                    if let track = AudioPlayerEngine.shared.currentTrack {
                        AudioPlayerEngine.shared.startWave(forTrack: track)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Divider()

                Menu("Качество звука") {
                    ForEach(YMAudioQualityPreset.allCases) { preset in
                        Button(preset.title) {
                            AudioPlayerEngine.shared.setAudioQualityPreset(preset)
                        }
                    }
                }

                Menu("Предпочитаемый кодек") {
                    ForEach(YMAudioCodecPreference.allCases) { codec in
                        Button(codec.title) {
                            AudioPlayerEngine.shared.setCodecPreference(codec)
                        }
                    }
                }
            }

            CommandMenu("Навигация") {
                Button("Поиск") {
                    NavigationCoordinator.shared.selectSection(.search)
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("Моя волна") {
                    NavigationCoordinator.shared.selectSection(.myWave)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Чарт") {
                    NavigationCoordinator.shared.selectSection(.chart)
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("Мне нравится") {
                    NavigationCoordinator.shared.selectSection(.favorites)
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button("Плейлисты") {
                    NavigationCoordinator.shared.selectSection(.playlists)
                }
                .keyboardShortcut("4", modifiers: [.command])

                Button("Настройки") {
                    NavigationCoordinator.shared.selectSection(.settings)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandMenu("Память") {
                Button(
                    AudioQualitySettings.shared.preloadAllFavoritesInBackground
                        ? "Отключить фоновую индексацию Избранного"
                        : "Включить фоновую индексацию Избранного"
                ) {
                    AudioQualitySettings.shared.setPreloadFavoritesInBackground(
                        !AudioQualitySettings.shared.preloadAllFavoritesInBackground
                    )
                }

                Menu("Лимит кэша обложек") {
                    Button("10 МБ") { AudioQualitySettings.shared.setImageCacheLimitMB(10) }
                    Button("15 МБ (По умолчанию)") { AudioQualitySettings.shared.setImageCacheLimitMB(15) }
                    Button("20 МБ") { AudioQualitySettings.shared.setImageCacheLimitMB(20) }
                    Button("50 МБ") { AudioQualitySettings.shared.setImageCacheLimitMB(50) }
                }

                Divider()

                Button("Сжать память (Выгрузить неиспользуемое)") {
                    AudioQualitySettings.shared.purgeUnusedMemory()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Очистить дисковый и сетевой кэш") {
                    Task {
                        await YMNetworkClient.shared.clearCache()
                        await ImagePipeline.shared.clearCache()
                    }
                }
            }
        }
        Settings {
            SettingsView()
                .preferredColorScheme(themeManager.currentTheme.colorScheme)
                .frame(minWidth: 500, minHeight: 420)
        }
    }
}
