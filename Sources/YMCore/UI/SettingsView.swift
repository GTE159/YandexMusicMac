import SwiftUI

/// Modernized, native macOS Settings view organized into sleek glass cards.
public struct SettingsView: View {
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var authService = AuthService.shared
    @UIState private var themeManager = YMThemeManager.shared
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
                    HStack(spacing: 16) {
                        Text("Тема оформления:")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(YMTheme.fg80)

                        Picker("", selection: Binding(
                            get: { themeManager.currentTheme },
                            set: { themeManager.setTheme($0) }
                        )) {
                            ForEach(YMAppTheme.allCases) { theme in
                                HStack {
                                    Image(systemName: theme.iconName)
                                    Text(theme.title)
                                }
                                .tag(theme)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 280)
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

                            Picker("", selection: Binding(
                                get: { audioEngine.qualitySettings.preset },
                                set: { audioEngine.setAudioQualityPreset($0) }
                            )) {
                                ForEach(YMAudioQualityPreset.allCases) { preset in
                                    Text(preset.title).tag(preset)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 250)
                        }

                        HStack(spacing: 12) {
                            Text("Предпочитаемый кодек:")
                                .font(.system(size: 13))
                                .foregroundStyle(YMTheme.fg80)

                            Picker("", selection: Binding(
                                get: { audioEngine.qualitySettings.codecPreference },
                                set: { audioEngine.setCodecPreference($0) }
                            )) {
                                ForEach(YMAudioCodecPreference.allCases) { codec in
                                    Text(codec.title).tag(codec)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 220)
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

                            Picker("", selection: Binding(
                                get: { audioEngine.qualitySettings.imageCacheLimitMB },
                                set: { audioEngine.qualitySettings.setImageCacheLimitMB($0) }
                            )) {
                                Text("10 МБ").tag(10)
                                Text("15 МБ (По умолчанию)").tag(15)
                                Text("20 МБ").tag(20)
                                Text("50 МБ").tag(50)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 190)
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
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(YMTheme.border, lineWidth: 1))
            )
        }
    }
}
