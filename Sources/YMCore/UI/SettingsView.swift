import SwiftUI

/// Modernized, native macOS Settings view organized into sleek glass cards.
public struct SettingsView: View {
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var authService = AuthService.shared
    @UIState private var themeManager = YMThemeManager.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    @UIState private var windowState = WindowState.shared
    @UIState private var rotorStore = RotorDiagnosticsStore.shared
    private let networkClient = YMNetworkClient.shared

    @UIState private var isMemoryCompressed = false
    @UIState private var isCacheCleared = false
    @UIState private var isScrolled = false
    @UIState private var compressFeedbackTask: Task<Void, Never>? = nil
    @UIState private var clearCacheFeedbackTask: Task<Void, Never>? = nil

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
                .padding(.top, windowState.topChromeContentPadding)

                Divider()
                    .overlay(YMTheme.border)

                // Section 0: Appearance & Theme
                settingsCard(title: "Внешний вид") {
                    VStack(spacing: 8) {
                        ForEach(YMAppTheme.allCases) { theme in
                            let isSelected = themeManager.currentTheme == theme
                            let previewPalette = YMTheme.palette(for: theme)
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

                                    // 3 overlapping palette swatches: background, surface card, accent
                                    HStack(spacing: -5) {
                                        Circle()
                                            .fill(previewPalette.bg)
                                            .frame(width: 14, height: 14)
                                            .overlay(Circle().strokeBorder(YMTheme.borderHover, lineWidth: 1))
                                        Circle()
                                            .fill(previewPalette.surface)
                                            .frame(width: 14, height: 14)
                                            .overlay(Circle().strokeBorder(YMTheme.borderHover, lineWidth: 1))
                                        Circle()
                                            .fill(previewPalette.accent)
                                            .frame(width: 14, height: 14)
                                            .overlay(Circle().strokeBorder(YMTheme.borderHover, lineWidth: 1))
                                    }
                                    .padding(.trailing, 4)

                                    ZStack {
                                        Circle()
                                            .strokeBorder(isSelected ? YMTheme.accent : YMTheme.borderHover, lineWidth: 1.5)
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
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSelected ? YMTheme.surfaceComponentHover : Color.clear)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(isSelected ? YMTheme.border : Color.clear, lineWidth: 1)
                                        )
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 460)
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
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                Text("Пресет качества звука:")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(YMTheme.fg80)
                                    .fixedSize(horizontal: true, vertical: false)

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

                            VStack(alignment: .leading, spacing: 8) {
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
                        }

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                Text("Предпочитаемый кодек:")
                                    .font(.system(size: 13))
                                    .foregroundStyle(YMTheme.fg80)
                                    .fixedSize(horizontal: true, vertical: false)

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

                            VStack(alignment: .leading, spacing: 8) {
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
                        }

                        Divider()
                            .overlay(YMTheme.border)

                        // Crossfade duration slider (0.0 ... 12.0 sec, 0.5 sec snap on release)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Плавный переход между треками (Crossfade)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(YMTheme.fg)

                                Spacer()

                                let duration = audioEngine.qualitySettings.crossfadeDuration
                                Text(duration < 0.5 ? "Выключен" : String(format: "%.1f сек", duration))
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(duration < 0.5 ? YMTheme.fg40 : YMTheme.accent)
                            }

                            YMSlider(
                                value: Binding(
                                    get: { audioEngine.qualitySettings.crossfadeDuration },
                                    set: { audioEngine.qualitySettings.setCrossfadeDuration($0) }
                                ),
                                in: 0...12,
                                activeColor: YMTheme.accent,
                                trackColor: YMTheme.surfaceComponentHover,
                                height: 4,
                                onEditingChanged: { editing in
                                    if !editing {
                                        let snapped = (audioEngine.qualitySettings.crossfadeDuration * 2.0).rounded() / 2.0
                                        audioEngine.qualitySettings.setCrossfadeDuration(snapped < 0.5 ? 0.0 : snapped)
                                    }
                                }
                            )
                            .frame(maxWidth: 420)

                            Text("Плавно затухает завершающийся трек и вводит следующий по кривой равной мощности (до 12 сек).")
                                .font(.caption)
                                .foregroundStyle(YMTheme.fg40)

                            if audioEngine.qualitySettings.exclusiveHogMode {
                                Text("(отключён при активном эксклюзивном режиме)")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)
                            }
                        }

                        Divider()
                            .overlay(YMTheme.border)

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

                // Section 2.5: Bit-Perfect / Exclusive CoreAudio HAL Output
                settingsCard(title: "Вывод звука и Hi-Res (CoreAudio HAL)") {
                    ExclusiveAudioSettingsCard()
                }

                // Section 3: Memory & Cache Optimization Card
                settingsCard(title: "Память и локальный кэш") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Клиент оптимизирован для удержания расхода ОЗУ в пределах 40–65 МБ благодаря аппаратному декодированию ImageIO, ограничению кэшей и изоляции поисковых буферов.")
                            .font(.caption)
                            .foregroundStyle(YMTheme.fg60)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                Text("Лимит кэша обложек в памяти:")
                                    .font(.system(size: 13))
                                    .foregroundStyle(YMTheme.fg80)
                                    .fixedSize(horizontal: true, vertical: false)

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

                            VStack(alignment: .leading, spacing: 8) {
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
                        }

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                purgeMemoryButton
                                clearDiskCacheButton
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                purgeMemoryButton
                                clearDiskCacheButton
                            }
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

                // Section 3.5: Offline Downloads & Encrypted Cache
                settingsCard(title: "Оффлайн-режим и скачанное") {
                    OfflineSettingsCard()
                }

                // Section 4: My Wave Algorithms & Rotor API Diagnostics (Bottom Card)
                rotorDiagnosticsCard
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 60)
            .background(alignment: .top) {
                if #unavailable(macOS 15.0) {
                    YMScrollTopSentinel(
                        coordinateSpaceName: "settings_scroll",
                        threshold: 48,
                        isScrolled: $isScrolled
                    )
                }
            }
        }
        .ymTrackScrollOffset(threshold: 48, isScrolled: $isScrolled)
        .coordinateSpace(name: "settings_scroll")
        .overlay(alignment: .top) {
            YMStickyTopBar(title: "Настройки", isVisible: isScrolled)
        }
        .onDisappear {
            compressFeedbackTask?.cancel()
            compressFeedbackTask = nil
            clearCacheFeedbackTask?.cancel()
            clearCacheFeedbackTask = nil
        }
        .ymScreenBackground()
    }

    @ViewBuilder
    private var rotorDiagnosticsCard: some View {
        let diag = rotorStore.diagnostics
        let statusColor: Color = if diag.activeLevel == 1 && !diag.isFallbackActive {
            Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
        } else if diag.isFallbackActive {
            YMTheme.accent
        } else {
            YMTheme.fg40
        }

        settingsCard(title: "Алгоритмы «Моей волны» и Rotor API") {
            VStack(alignment: .leading, spacing: 14) {
                // 1. Protocol Mode Picker
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text("Режим протокола Rotor API:")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(YMTheme.fg80)
                            .fixedSize(horizontal: true, vertical: false)

                        rotorModePicker
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Режим протокола Rotor API:")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(YMTheme.fg80)

                        rotorModePicker
                    }
                }

                Divider()
                    .overlay(YMTheme.border)

                // 2. Active Protocol Status Badge
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)

                        Text(diag.isFallbackActive ? "Активен резервный уровень (Fallback)" : (diag.activeLevel == 1 ? "Активен основной протокол" : "Ожидание запуска волны"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(statusColor)

                        Spacer(minLength: 8)

                        if diag.fetchedTracksCount > 0 || diag.filteredDuplicatesCount > 0 {
                            Text("Загружено: \(diag.fetchedTracksCount) • Дублей отфильтровано: \(diag.filteredDuplicatesCount)")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(YMTheme.fg60)
                        }
                    }

                    Text(diag.activeProtocol)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(YMTheme.fg)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(YMTheme.surfaceComponent)
                        )

                    // Session metadata
                    VStack(alignment: .leading, spacing: 4) {
                        rotorMetaRow(label: "radioSessionId:", value: diag.sessionId ?? "—")
                        rotorMetaRow(label: "batchId:", value: diag.batchId ?? "—")
                        rotorMetaRow(
                            label: "Активные seeds:",
                            value: diag.activeSeeds.isEmpty ? "—" : diag.activeSeeds.joined(separator: ", ")
                        )
                    }
                    .padding(.top, 2)
                }

                Divider()
                    .overlay(YMTheme.border)

                // 3. Supported 4-Level Fallback Chain
                VStack(alignment: .leading, spacing: 8) {
                    Text("Цепочка протоколов и уровней Fallback (по приоритету):")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(YMTheme.fg80)

                    rotorFallbackLevelRow(
                        level: 1,
                        activeLevel: diag.activeLevel,
                        isPrimary: true,
                        title: "Уровень 1 (Основной): Rotor Session v2",
                        detail: "POST /rotor/session/new и /tracks — персональная ML-модель волны и комбинированные сиды"
                    )

                    rotorFallbackLevelRow(
                        level: 2,
                        activeLevel: diag.activeLevel,
                        isPrimary: false,
                        title: "Уровень 2 (Резерв сидов v2): Rotor Session v2 Simplified",
                        detail: "Повторная инициализация v2 с базовыми сидами при ошибке составного контекста"
                    )

                    rotorFallbackLevelRow(
                        level: 3,
                        activeLevel: diag.activeLevel,
                        isPrimary: false,
                        title: "Уровень 3 (Резерв API v1): Rotor Station v1",
                        detail: "GET /rotor/station/{stationId}/tracks?settings2=true — классический протокол радиостанций"
                    )

                    rotorFallbackLevelRow(
                        level: 4,
                        activeLevel: diag.activeLevel,
                        isPrimary: false,
                        title: "Уровень 4 (Базовый резерв): Default Personal Wave",
                        detail: "GET /rotor/station/user:onyourwave/tracks?settings2=true — аварийный возврат к базовой персональной волне"
                    )
                }

                // 4. Last Fallback Reason (if any)
                if let reason = diag.lastFallbackReason, !reason.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(YMTheme.accent)
                            .padding(.top, 1)

                        Text("Причина последнего переключения: \(reason)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(YMTheme.fg80)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(YMTheme.accent.opacity(0.10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(YMTheme.accent.opacity(0.25), lineWidth: 1)
                            )
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var rotorModePicker: some View {
        YMPopupMenu(
            selectedTitle: rotorStore.preferredAPIMode.title,
            options: YMRotorAPIMode.allCases.map { ($0, $0.title) },
            selection: Binding(
                get: { rotorStore.preferredAPIMode },
                set: { newMode in
                    rotorStore.preferredAPIMode = newMode
                    Task {
                        await RotorService.shared.setPreferredAPIMode(newMode)
                    }
                }
            ),
            width: 260
        )
    }

    @ViewBuilder
    private func rotorMetaRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(YMTheme.fg40)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(YMTheme.fg80)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func rotorFallbackLevelRow(
        level: Int,
        activeLevel: Int,
        isPrimary: Bool,
        title: String,
        detail: String
    ) -> some View {
        let isActive = (level == activeLevel)
        let highlightColor: Color = isPrimary
            ? Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
            : YMTheme.accent

        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(isActive ? highlightColor.opacity(0.20) : YMTheme.surfaceComponent)
                    .frame(width: 22, height: 22)

                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(highlightColor)
                } else {
                    Text("\(level)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(YMTheme.fg40)
                }
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: isActive ? .bold : .semibold))
                        .foregroundStyle(isActive ? YMTheme.fg : YMTheme.fg80)

                    if isActive {
                        Text("АКТИВЕН")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(highlightColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(highlightColor.opacity(0.16)))
                    }
                }

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(YMTheme.fg40)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? highlightColor.opacity(0.08) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isActive ? highlightColor.opacity(0.30) : YMTheme.border, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var purgeMemoryButton: some View {
        Button {
            audioEngine.qualitySettings.purgeUnusedMemory()
            isMemoryCompressed = true
            compressFeedbackTask?.cancel()
            compressFeedbackTask = Task {
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                guard !Task.isCancelled else { return }
                isMemoryCompressed = false
            }
        } label: {
            Text("Выгрузить неиспользуемую память")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 32))
    }

    @ViewBuilder
    private var clearDiskCacheButton: some View {
        Button {
            clearCacheFeedbackTask?.cancel()
            clearCacheFeedbackTask = Task {
                await networkClient.clearCache()
                ImagePipeline.shared.clearCache()
                YMBackdropBlurProcessor.shared.clearCache()
                isCacheCleared = true
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                guard !Task.isCancelled else { return }
                isCacheCleared = false
            }
        } label: {
            Text("Очистить дисковый кэш")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 32))
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(YMTheme.surfaceComponent)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(YMTheme.border, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(YMTheme.fg)
        .frame(width: width)
    }
}

// MARK: - Isolated Offline Settings Card Content

private struct OfflineSettingsCard: View {
    @UIState private var qualitySettings = AudioQualitySettings.shared
    @UIState private var offlineManager = OfflineDownloadManager.shared
    @UIState private var isDeleteConfirmPresented = false
    @UIState private var isClearedFeedback = false
    @UIState private var feedbackTask: Task<Void, Never>? = nil
    @UIState private var customLimitInput: String = ""
    @UIState private var customLimitError: String? = nil

    private let offlinePresets: [YMAudioQualityPreset] = [.lossless, .high320, .medium192, .standard128]
    private let limitOptions: [(Int, String)] = [
        (2, "2 ГБ"),
        (5, "5 ГБ (По умолчанию)"),
        (10, "10 ГБ"),
        (20, "20 ГБ"),
        (-1, "Свой..."),
        (0, "Без лимита")
    ]

    private var selectedMenuTag: Int {
        qualitySettings.offlineCacheCustomLimitEnabled ? -1 : qualitySettings.offlineCacheLimitGB
    }

    private var selectedLimitTitle: String {
        if qualitySettings.offlineCacheCustomLimitEnabled {
            return "Свой (\(qualitySettings.effectiveOfflineCacheLimitDisplay))"
        }
        return limitTitle(qualitySettings.offlineCacheLimitGB)
    }

    private func limitTitle(_ gb: Int) -> String {
        switch gb {
        case -1: return "Свой..."
        case 0: return "Без лимита"
        case 5: return "5 ГБ (По умолчанию)"
        default: return "\(gb) ГБ"
        }
    }

    private func syncCustomLimitInputFromSettings() {
        customLimitInput = Self.plainNumberString(qualitySettings.offlineCacheCustomLimitGB)
        customLimitError = nil
    }

    private static func plainNumberString(_ gb: Double) -> String {
        let normalized = AudioQualitySettings.normalizedCustomCacheLimitGB(gb)
        let rounded = normalized.rounded()
        if abs(normalized - rounded) < 0.005 {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", normalized)
    }

    private func applyCustomLimitInput() {
        guard let parsed = AudioQualitySettings.parseCustomCacheLimitGB(customLimitInput) else {
            customLimitError = "Введите число от 0.1 до 500 ГБ"
            return
        }
        customLimitError = nil
        qualitySettings.setOfflineCacheCustomLimitGB(parsed)
        qualitySettings.setOfflineCacheCustomLimitEnabled(true)
        customLimitInput = Self.plainNumberString(parsed)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Скачанные треки шифруются локальным ключом устройства (AES-256-GCM) и воспроизводятся без интернета.")
                .font(.caption)
                .foregroundStyle(YMTheme.fg60)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text("Качество скачивания:")
                        .font(.system(size: 13))
                        .foregroundStyle(YMTheme.fg80)
                        .fixedSize(horizontal: true, vertical: false)

                    qualityMenu
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Качество скачивания:")
                        .font(.system(size: 13))
                        .foregroundStyle(YMTheme.fg80)

                    qualityMenu
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text("Лимит места на диске:")
                        .font(.system(size: 13))
                        .foregroundStyle(YMTheme.fg80)
                        .fixedSize(horizontal: true, vertical: false)

                    limitMenu
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Лимит места на диске:")
                        .font(.system(size: 13))
                        .foregroundStyle(YMTheme.fg80)

                    limitMenu
                }
            }

            if qualitySettings.offlineCacheCustomLimitEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Свой лимит:")
                            .font(.system(size: 12.5))
                            .foregroundStyle(YMTheme.fg60)

                        TextField("0.1 – 500", text: $customLimitInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(YMTheme.fg)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(width: 100)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(YMTheme.surfaceComponent)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(customLimitError != nil ? Color.orange.opacity(0.6) : YMTheme.border, lineWidth: 1)
                                    )
                            )
                            .onSubmit {
                                applyCustomLimitInput()
                            }

                        Text("ГБ")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(YMTheme.fg60)

                        Button("Применить") {
                            applyCustomLimitInput()
                        }
                        .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 28))
                    }

                    if let customLimitError {
                        Text(customLimitError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Допустимо от 0.1 до 500 ГБ (текущий лимит: \(qualitySettings.effectiveOfflineCacheLimitDisplay)).")
                            .font(.caption)
                            .foregroundStyle(YMTheme.fg40)
                    }
                }
                .padding(.leading, 2)
            }

            let activeLimitBytes = qualitySettings.effectiveOfflineCacheLimitBytes
            if activeLimitBytes > 0 && offlineManager.totalUsedBytes >= activeLimitBytes {
                Text("Текущий объём кэша достиг выбранного лимита (\(qualitySettings.effectiveOfflineCacheLimitDisplay)) — новые загрузки приостановлены.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()
                .overlay(YMTheme.border)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Занято в оффлайн-кэше: \(formattedByteCount(offlineManager.totalUsedBytes))")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(YMTheme.fg)
                    Text("Сохранено: \(formatTrackCount(offlineManager.downloadedRecords.count))")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg60)
                }

                Spacer()

                Button {
                    isDeleteConfirmPresented = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("Удалить все скачанные треки")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(Color.red.opacity(0.9))
                }
                .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 32))
                .disabled(offlineManager.downloadedRecords.isEmpty && offlineManager.activeDownloadsCount == 0)
            }

            if isClearedFeedback {
                Text("✓ Все скачанные треки удалены.")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
        .alert("Удалить все скачанные треки?", isPresented: $isDeleteConfirmPresented) {
            Button("Удалить", role: .destructive) {
                Task {
                    await offlineManager.deleteAllDownloads()
                    isClearedFeedback = true
                    feedbackTask?.cancel()
                    feedbackTask = Task {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        guard !Task.isCancelled else { return }
                        isClearedFeedback = false
                    }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Зашифрованные аудиофайлы и сохранённые тексты песен будут удалены с этого Mac.")
        }
        .onDisappear {
            feedbackTask?.cancel()
            feedbackTask = nil
        }
        .onAppear {
            syncCustomLimitInputFromSettings()
        }
        .task {
            await offlineManager.loadIndexIfNeeded()
        }
    }

    @ViewBuilder
    private var qualityMenu: some View {
        YMPopupMenu(
            selectedTitle: qualitySettings.offlineQualityPreset.title,
            options: offlinePresets.map { ($0, $0.title) },
            selection: Binding(
                get: { qualitySettings.offlineQualityPreset },
                set: { qualitySettings.setOfflineQualityPreset($0) }
            ),
            width: 240
        )
    }

    @ViewBuilder
    private var limitMenu: some View {
        YMPopupMenu(
            selectedTitle: selectedLimitTitle,
            options: limitOptions,
            selection: Binding(
                get: { selectedMenuTag },
                set: { newValue in
                    if newValue == -1 {
                        qualitySettings.setOfflineCacheCustomLimitEnabled(true)
                        syncCustomLimitInputFromSettings()
                    } else {
                        customLimitError = nil
                        qualitySettings.setOfflineCacheLimitGB(newValue)
                        qualitySettings.setOfflineCacheCustomLimitEnabled(false)
                    }
                }
            ),
            width: 220
        )
    }
}

// MARK: - CoreAudio HAL / Bit-Perfect Output Settings Card

private struct ExclusiveAudioSettingsCard: View {
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var qualitySettings = AudioQualitySettings.shared
    @UIState private var deviceManager = CoreAudioDeviceManager.shared

    private var deviceOptions: [(String, String)] {
        var options: [(String, String)] = [("", "Системное по умолчанию")]
        for dev in deviceManager.outputDevices {
            let suffix = dev.isDefaultOutput ? " · по умолчанию" : ""
            options.append((dev.uid, "\(dev.name) (\(dev.transport.badgeLabel)\(suffix))"))
        }
        let currentUID = qualitySettings.audioOutputDeviceUID
        if !currentUID.isEmpty && !options.contains(where: { $0.0 == currentUID }) {
            options.append((currentUID, "Выбранное устройство (отключено)"))
        }
        return options
    }

    private var selectedDeviceTitle: String {
        let currentUID = qualitySettings.audioOutputDeviceUID
        return deviceOptions.first(where: { $0.0 == currentUID })?.1 ?? "Системное по умолчанию"
    }

    private var selectedDeviceInfo: AudioOutputDeviceInfo? {
        if qualitySettings.audioOutputDeviceUID.isEmpty {
            return deviceManager.outputDevices.first(where: { $0.isDefaultOutput }) ?? deviceManager.outputDevices.first
        }
        return deviceManager.outputDevices.first(where: { $0.uid == qualitySettings.audioOutputDeviceUID })
    }

    private func formatSampleRate(_ hz: Double) -> String {
        let rounded = Int(hz.rounded())
        if rounded % 1000 == 0 {
            return "\(rounded / 1000) кГц"
        }
        return String(format: "%.1f кГц", hz / 1000.0)
    }

    private var currentBackendLabel: String {
        if audioEngine.isExclusiveHogActive {
            return audioEngine.isVolumeBypassedForBitPerfect ? "Bit-Perfect (Hog Mode · 0 дБ)" : "Exclusive Hog Mode"
        }
        if audioEngine.isDirectHALActive {
            return "Direct HAL"
        }
        return qualitySettings.usesDirectHALBackend ? "CoreAudio HAL (ожидание старта)" : "Стандартный плеер (AVPlayer)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text("Устройство вывода:")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(YMTheme.fg80)
                        .fixedSize(horizontal: true, vertical: false)

                    deviceSelectorRow
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Устройство вывода:")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(YMTheme.fg80)

                    deviceSelectorRow
                }
            }

            Toggle(isOn: Binding(
                get: { qualitySettings.autoSampleRateSwitching },
                set: { qualitySettings.setAutoSampleRateSwitching($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Автопереключение частоты дискретизации ЦАПа")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(YMTheme.fg)
                    Text("Подстраивает частоту вывода (44.1 / 48 / 88.2 / 96 / 192 кГц) под каждый трек без системного ресемплинга.")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg40)
                }
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: Binding(
                get: { qualitySettings.exclusiveHogMode },
                set: { qualitySettings.setExclusiveHogMode($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Эксклюзивный режим захвата (Hog Mode / Bit-Perfect)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(YMTheme.fg)
                    Text("Монопольно захватывает аудиоустройство, обходит системный микшер macOS, отключает эквалайзер и кроссфейд.")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg40)
                }
            }
            .toggleStyle(.checkbox)

            if qualitySettings.exclusiveHogMode {
                Toggle(isOn: Binding(
                    get: { qualitySettings.bitPerfectFixedVolume },
                    set: { qualitySettings.setBitPerfectFixedVolume($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Фиксированная громкость 0 дБ (управление на ЦАПе)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(YMTheme.fg)
                        Text("Отключает программное масштабирование амплитуды семплов (unity gain 1.0) для побитовой передачи.")
                            .font(.caption)
                            .foregroundStyle(YMTheme.fg40)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.leading, 22)
            }

            Divider()
                .overlay(YMTheme.border)

            // Live device & HAL output status row
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(audioEngine.isExclusiveHogActive ? YMTheme.accent : (audioEngine.isDirectHALActive ? Color.green : YMTheme.fg40))
                        .frame(width: 8, height: 8)

                    Text("Режим: \(currentBackendLabel)")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(YMTheme.fg)

                    Spacer()

                    if let rate = audioEngine.activeDeviceSampleRate ?? selectedDeviceInfo?.nominalSampleRate {
                        Text(formatSampleRate(rate))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(YMTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(YMTheme.accent.opacity(0.14)))
                    }
                }

                if let activeName = audioEngine.activeOutputDeviceName ?? selectedDeviceInfo?.name {
                    Text("Активное устройство: \(activeName)")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg60)
                }

                if let details = audioEngine.currentAudioFormatDetails {
                    Text("Сигнал: \(details)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(YMTheme.fg60)
                }
            }

            if let warning = audioEngine.halStatusWarning, !warning.isEmpty {
                halWarningBanner(warning)
            } else if let dev = selectedDeviceInfo,
                      !dev.transport.supportsExclusiveMode,
                      (qualitySettings.exclusiveHogMode || qualitySettings.autoSampleRateSwitching) {
                halWarningBanner("Устройство \(dev.name) (\(dev.transport.badgeLabel)) не поддерживает эксклюзивный захват — будет использоваться прямой вывод без Hog Mode.")
            }
        }
        .onAppear {
            deviceManager.refreshDevices()
        }
    }

    @ViewBuilder
    private var deviceSelectorRow: some View {
        HStack(spacing: 8) {
            YMPopupMenu(
                selectedTitle: selectedDeviceTitle,
                options: deviceOptions,
                selection: Binding(
                    get: { qualitySettings.audioOutputDeviceUID },
                    set: { qualitySettings.setAudioOutputDeviceUID($0) }
                ),
                width: 280
            )

            Button {
                deviceManager.refreshDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(YMTheme.fg80)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(YMTheme.surfaceComponent)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(YMTheme.border, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .help("Обновить список аудиоустройств")
        }
    }

    @ViewBuilder
    private func halWarningBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            Text(text)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.30), lineWidth: 1)
                )
        )
    }
}
