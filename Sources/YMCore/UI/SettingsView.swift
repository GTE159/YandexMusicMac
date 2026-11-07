import SwiftUI

/// Modernized, native macOS Settings view organized into sleek glass cards.
public struct SettingsView: View {
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var authService = AuthService.shared
    @UIState private var themeManager = YMThemeManager.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    private let networkClient = YMNetworkClient.shared

    @UIState private var isMemoryCompressed = false
    @UIState private var isCacheCleared = false

    public init() {}

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Настройки")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(YMTheme.fg)

                    Text("Параметры воспроизведения, звука, темы и управления памятью")
                        .font(.subheadline)
                        .foregroundStyle(YMTheme.fg60)
                }
                .padding(.top, 20)

                Divider()
                    .overlay(YMTheme.border)

                // Section 0: Appearance & Theme
                settingsCard(title: "Внешний вид") {
                    VStack(spacing: 8) {
                        ForEach(YMAppTheme.allCases) { theme in
                            let isSelected = themeManager.currentTheme == theme
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    themeManager.setTheme(theme)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: theme.iconName)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(isSelected ? YMTheme.accent : YMTheme.fg60)
                                        .frame(width: 24, height: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(theme.title)
                                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                            .foregroundStyle(YMTheme.fg)

                                        Text(theme.subtitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(YMTheme.fg40)
                                    }

                                    Spacer()

                                    ZStack {
                                        Circle()
                                            .strokeBorder(isSelected ? YMTheme.accent : YMTheme.border, lineWidth: 1.5)
                                            .frame(width: 18, height: 18)

                                        if isSelected {
                                            Circle()
                                                .fill(YMTheme.accent)
                                                .frame(width: 10, height: 10)
                                        }
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isSelected ? YMTheme.surfaceComponentHover : Color.clear)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(isSelected ? YMTheme.borderHover : Color.clear, lineWidth: 1)
                                        )
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 440)
                }

                // Section 0.5: Lyrics & Karaoke Position
                settingsCard(title: "Текст песен и караоке") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Расположение субтитров во время воспроизведения трека:")
                            .font(.system(size: 12))
                            .foregroundStyle(YMTheme.fg60)

                        VStack(spacing: 8) {
                            ForEach(YMLyricsPosition.allCases) { position in
                                let isSelected = coordinator.lyricsPosition == position
                                Button {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        coordinator.lyricsPosition = position
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: position == .right ? "sidebar.right" : "dock.rectangle")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(isSelected ? YMTheme.accent : YMTheme.fg60)
                                            .frame(width: 24, height: 24)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(position.title)
                                                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                                .foregroundStyle(YMTheme.fg)

                                            Text(position.subtitle)
                                                .font(.system(size: 11))
                                                .foregroundStyle(YMTheme.fg40)
                                        }

                                        Spacer()

                                        ZStack {
                                            Circle()
                                                .strokeBorder(isSelected ? YMTheme.accent : YMTheme.border, lineWidth: 1.5)
                                                .frame(width: 18, height: 18)

                                            if isSelected {
                                                Circle()
                                                    .fill(YMTheme.accent)
                                                    .frame(width: 10, height: 10)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(isSelected ? YMTheme.surfaceComponentHover : Color.clear)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .strokeBorder(isSelected ? YMTheme.borderHover : Color.clear, lineWidth: 1)
                                            )
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: 440)
                    }
                }

                // Section 1: User Account Card
                if let user = authService.currentUser {
                    settingsCard(title: "Аккаунт Яндекс") {
                        HStack(spacing: 16) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(YMTheme.accent)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(user.displayName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(YMTheme.fg)

                                if user.hasActiveSubscription {
                                    HStack(spacing: 4) {
                                        Image(systemName: "sparkles")
                                            .font(.caption2)
                                        Text("Яндекс Плюс активен")
                                            .font(.caption.weight(.medium))
                                    }
                                    .foregroundStyle(YMTheme.accent)
                                } else {
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                        Text("Подписка Яндекс Плюс не активна")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.orange)

                                        Button("Оформить") {
                                            if let url = URL(string: "https://plus.yandex.ru/") {
                                                NSWorkspace.shared.open(url)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(YMTheme.accent)
                                    }
                                }
                            }

                            Spacer()

                            Button("Выйти из аккаунта") {
                                authService.signOut()
                            }
                            .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 30))
                        }
                    }
                }

                // Section 2: Audio & Streaming Quality Card
                settingsCard(title: "Качество звука и стриминг") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Text("Пресет качества звука:")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(YMTheme.fg80)

                            YMPopupMenu(
                                selectedTitle: audioEngine.qualitySettings.preset.title,
                                options: YMAudioQualityPreset.allCases.map { ($0, $0.title) },
                                selection: Binding(
                                    get: { audioEngine.qualitySettings.preset },
                                    set: { audioEngine.setAudioQualityPreset($0) }
                                ),
                                width: 250
                            )
                        }

                        HStack(spacing: 12) {
                            Text("Предпочитаемый кодек:")
                                .font(.system(size: 13))
                                .foregroundStyle(YMTheme.fg80)

                            YMPopupMenu(
                                selectedTitle: audioEngine.qualitySettings.codecPreference.title,
                                options: YMAudioCodecPreference.allCases.map { ($0, $0.title) },
                                selection: Binding(
                                    get: { audioEngine.qualitySettings.codecPreference },
                                    set: { audioEngine.setCodecPreference($0) }
                                ),
                                width: 220
                            )
                        }

                        Toggle(isOn: Binding(
                            get: { audioEngine.qualitySettings.preloadAllFavoritesInBackground },
                            set: { audioEngine.qualitySettings.setPreloadFavoritesInBackground($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Фоновая индексация всей библиотеки «Мне нравится»")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(YMTheme.fg)
                                Text("Позволяет мгновенно искать по десяткам тысяч треков, удерживая расход памяти в норме")
                                    .font(.caption)
                                    .foregroundStyle(YMTheme.fg40)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }

                // Section 3: Memory & Cache Optimization Card
                settingsCard(title: "Память и локальный кэш") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Клиент оптимизирован для удержания расхода ОЗУ в пределах 40–65 МБ благодаря аппаратному декодированию ImageIO, ограничению кэшей и изоляции поисковых буферов.")
                            .font(.caption)
                            .foregroundStyle(YMTheme.fg60)

                        HStack(spacing: 12) {
                            Text("Лимит кэша обложек в памяти:")
                                .font(.system(size: 13))
                                .foregroundStyle(YMTheme.fg80)

                            YMPopupMenu(
                                selectedTitle: cacheLimitTitle(audioEngine.qualitySettings.imageCacheLimitMB),
                                options: [
                                    (10, "10 МБ"),
                                    (15, "15 МБ (По умолчанию)"),
                                    (20, "20 МБ"),
                                    (50, "50 МБ")
                                ],
                                selection: Binding(
                                    get: { audioEngine.qualitySettings.imageCacheLimitMB },
                                    set: { audioEngine.qualitySettings.setImageCacheLimitMB($0) }
                                ),
                                width: 200
                            )
                        }

                        HStack(spacing: 12) {
                            Button("Выгрузить неиспользуемую память") {
                                audioEngine.qualitySettings.purgeUnusedMemory()
                                isMemoryCompressed = true
                            }
                            .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 32))

                            Button("Очистить дисковый кэш") {
                                Task {
                                    await networkClient.clearCache()
                                    await ImagePipeline.shared.clearCache()
                                    isCacheCleared = true
                                }
                            }
                            .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 32))
                        }

                        if isMemoryCompressed {
                            Text("✓ Неиспользуемые данные и кэши выгружены из ОЗУ.")
                                .font(.caption)
                                .foregroundColor(.green)
                        }

                        if isCacheCleared {
                            Text("✓ Дисковый и сетевой кэш обложек полностью очищен.")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 60)
        }
        .ymScreenBackground()
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(YMTheme.fg)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(YMTheme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(YMTheme.border, lineWidth: 1))
                    .shadow(color: YMTheme.shadowColor, radius: 4, y: 1)
            )
        }
    }

    private func cacheLimitTitle(_ mb: Int) -> String {
        switch mb {
        case 10: return "10 МБ"
        case 15: return "15 МБ (По умолчанию)"
        case 20: return "20 МБ"
        case 50: return "50 МБ"
        default: return "\(mb) МБ"
        }
    }
}

// MARK: - Modern Theme-Aware Popup Menu

private struct YMPopupMenu<T: Hashable>: View {
    let selectedTitle: String
    let options: [(T, String)]
    let selection: Binding<T>
    let width: CGFloat

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { item, label in
                Button {
                    selection.wrappedValue = item
                } label: {
                    HStack {
                        Text(label)
                        if selection.wrappedValue == item {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(YMTheme.fg)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(YMTheme.fg40)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(YMTheme.isLight ? Color(red: 228 / 255, green: 226 / 255, blue: 220 / 255) : YMTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(YMTheme.borderHover, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(YMTheme.fg)
        .frame(width: width)
    }
}
