import SwiftUI
import AppKit
import YMCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTouchBarProvider {
    weak var mainWindow: NSWindow?

    var touchBar: NSTouchBar? {
        YMTouchBarController.shared.touchBar
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // Гарантируем, что приложение работает как полноценное GUI-приложение с иконкой в Dock
        NSApp.setActivationPolicy(.regular)
        applyAppIconIfNeeded()
        YMTouchBarController.shared.install()
        NSApp.activate(ignoringOtherApps: true)
        configureMainWindowIfNeeded()
        localizeSystemMenusToRussian()
        DispatchQueue.main.async { [weak self] in
            self?.localizeSystemMenusToRussian()
        }
    }

    private func applyAppIconIfNeeded() {
        if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: icnsURL) {
            NSApp.applicationIconImage = icon
        } else if let pngURL = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
                  let icon = NSImage(contentsOf: pngURL) {
            NSApp.applicationIconImage = icon
        }
    }

    /// Вызывается macOS при клике на иконку приложения в Dock
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || mainWindow?.isVisible == false {
            showMainWindow()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        configureMainWindowIfNeeded()
        localizeSystemMenusToRussian()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioPlayerEngine.shared.cleanup()
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
            window.tabbingMode = .disallowed
            guard WindowState.shared.isValidAppWindow(window) else { continue }
            if mainWindow == nil {
                mainWindow = window
            }
            guard window === mainWindow else { continue }
            if window.delegate !== self {
                window.delegate = self
            }
            window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
            window.title = ""
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 440, height: 320)
            window.toolbar = nil
            window.isMovableByWindowBackground = false
            YMTouchBarController.shared.attachToWindow(window)
            for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(buttonType)?.isHidden = false
            }
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

    /// Translates standard AppKit/SwiftUI system menu items to Russian so the menu bar is localized
    /// both when launched as an `.app` bundle and when launched directly as a raw SwiftPM binary.
    func localizeSystemMenusToRussian() {
        guard let mainMenu = NSApp.mainMenu else { return }

        let topLevelTranslations: [String: String] = [
            "File": "Файл",
            "Edit": "Правка",
            "View": "Вид",
            "Window": "Окно",
            "Help": "Справка"
        ]

        let itemTranslations: [String: String] = [
            "About YandexMusicMac": "О приложении flow~",
            "About flow~": "О приложении flow~",
            "Settings…": "Настройки…",
            "Settings...": "Настройки…",
            "Preferences…": "Настройки…",
            "Services": "Службы",
            "Hide": "Скрыть",
            "Hide YandexMusicMac": "Скрыть flow~",
            "Hide flow~": "Скрыть flow~",
            "Hide Others": "Скрыть остальные",
            "Show All": "Показать все",
            "Quit": "Завершить",
            "Quit YandexMusicMac": "Завершить flow~",
            "Quit flow~": "Завершить flow~",
            "Close": "Закрыть",
            "Undo": "Отменить",
            "Redo": "Повторить",
            "Cut": "Вырезать",
            "Copy": "Копировать",
            "Paste": "Вставить",
            "Paste and Match Style": "Вставить с текущим стилем",
            "Delete": "Удалить",
            "Select All": "Выделить всё",
            "Find": "Найти",
            "Spelling and Grammar": "Правописание и грамматика",
            "Substitutions": "Замены",
            "Transformations": "Преобразования",
            "Speech": "Речь",
            "Start Dictation…": "Начать диктовку…",
            "Emoji & Symbols": "Эмодзи и символы",
            "Show Sidebar": "Показать боковое меню",
            "Hide Sidebar": "Скрыть боковое меню",
            "Customize Touch Bar…": "Настроить Touch Bar…",
            "Customize Touch Bar...": "Настроить Touch Bar…",
            "Enter Full Screen": "Перейти в полноэкранный режим",
            "Exit Full Screen": "Выйти из полноэкранного режима",
            "Minimize": "Свернуть",
            "Zoom": "Изменить размер",
            "Fill": "Заполнить",
            "Center": "По центру",
            "Move & Resize": "Переместить и изменить размер",
            "Full Screen Tile": "Полноэкранная плитка",
            "Remove Window from Set": "Удалить окно из набора",
            "Show Tab Bar": "Показать панель вкладок",
            "Show All Tabs": "Показать все вкладки",
            "Bring All to Front": "Все окна на передний план"
        ]

        // Ensure application menu title is "flow~"
        if let appMenuItem = mainMenu.items.first {
            appMenuItem.title = "flow~"
            appMenuItem.submenu?.title = "flow~"
        }

        func translateMenu(_ menu: NSMenu, isTopLevel: Bool) {
            if let mapped = topLevelTranslations[menu.title] {
                menu.title = mapped
            }
            for item in menu.items {
                if isTopLevel, let mapped = topLevelTranslations[item.title] {
                    item.title = mapped
                } else if let mapped = itemTranslations[item.title] {
                    item.title = mapped
                } else if item.title.hasPrefix("About ") {
                    item.title = "О приложении flow~"
                } else if item.title.hasPrefix("Hide ") && item.title != "Hide Others" && item.title != "Hide Sidebar" {
                    item.title = "Скрыть flow~"
                } else if item.title.hasPrefix("Quit ") {
                    item.title = "Завершить flow~"
                } else if item.title.hasSuffix(" Help") {
                    item.title = "Справка flow~"
                }

                if let submenu = item.submenu {
                    if let mappedSub = topLevelTranslations[submenu.title] {
                        submenu.title = mappedSub
                    }
                    translateMenu(submenu, isTopLevel: false)
                }
            }
        }

        translateMenu(mainMenu, isTopLevel: true)
    }
}

private struct PlaybackCommands: Commands {
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var eqSettings = EqualizerSettings.shared

    var body: some Commands {
        CommandMenu("Воспроизведение") {
            Button(audioEngine.isPlaying ? "Пауза" : "Воспроизведение") {
                audioEngine.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Следующий трек") {
                audioEngine.next()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command])

            Button("Предыдущий трек") {
                audioEngine.previous()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command])

            Button("Вперед на 5 секунд") {
                audioEngine.seekRelative(by: 5.0)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Button("Назад на 5 секунд") {
                audioEngine.seekRelative(by: -5.0)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Divider()

            Button("Увеличить громкость") {
                audioEngine.volume = min(1.0, audioEngine.volume + 0.1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])

            Button("Уменьшить громкость") {
                audioEngine.volume = max(0.0, audioEngine.volume - 0.1)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])

            Button("Мне нравится / Удалить из избранного") {
                if let track = audioEngine.currentTrack {
                    Task { await LikesService.shared.toggleLike(track: track) }
                }
            }
            .keyboardShortcut("l", modifiers: [.command])

            Divider()

            Button("Перемешать очередь") {
                audioEngine.toggleShuffle()
            }
            .keyboardShortcut("s", modifiers: [.command])

            Button("Волна по текущему треку") {
                if let track = audioEngine.currentTrack {
                    audioEngine.startWave(forTrack: track)
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])

            Button(eqSettings.isEnabled ? "Выключить эквалайзер" : "Включить эквалайзер") {
                eqSettings.isEnabled.toggle()
            }
            .keyboardShortcut("e", modifiers: [.command])

            Divider()

            Menu("Качество звука") {
                ForEach(YMAudioQualityPreset.allCases) { preset in
                    Button(preset.title) {
                        audioEngine.setAudioQualityPreset(preset)
                    }
                }
            }

            Menu("Предпочитаемый кодек") {
                ForEach(YMAudioCodecPreference.allCases) { codec in
                    Button(codec.title) {
                        audioEngine.setCodecPreference(codec)
                    }
                }
            }
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
                DispatchQueue.main.async {
                    appDelegate.configureMainWindowIfNeeded()
                }
                appDelegate.localizeSystemMenusToRussian()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
        .commands {
            // Disable creating extra windows / tabs via ⌘N
            CommandGroup(replacing: .newItem) {}

            PlaybackCommands()

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

                Button("Скачанное") {
                    NavigationCoordinator.shared.selectSection(.downloads)
                }
                .keyboardShortcut("5", modifiers: [.command])

                Button("Настройки") {
                    NavigationCoordinator.shared.selectSection(.settings)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
        Settings {
            SettingsView()
                .preferredColorScheme(themeManager.currentTheme.colorScheme)
                .frame(minWidth: 500, minHeight: 420)
        }
    }
}
