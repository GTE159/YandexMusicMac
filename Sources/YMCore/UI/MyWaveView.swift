import SwiftUI

// MARK: - Wave Session Controller

/// Centralized manager for "Моя волна" state and background queue expansion.
/// Replaces temporary SwiftUI struct closures with strong/weak lifecycle hooks,
/// allowing custom waves (by artist, playlist, track) and background pagination to work seamlessly from any view.
@Observable
@MainActor
public final class WaveSessionController {
    public static let shared = WaveSessionController()

    public var waveTracks: [YMTrack] = []
    public var dashboardStations: [YMPersonalWaveStation] = []
    public var isLoadingDashboard = false
    public var isLoadingWave = false
    public var isLoadingMoreWave = false
    public var errorMessage: String? = nil
    public var toastMessage: String? = nil

    public let tasteTracker = WaveSessionTasteTracker()
    public var activeSavedWaveId: UUID? = nil
    public var activeSavedWave: SavedWavePreset? {
        activeSavedWaveId.flatMap { SavedWavePresetStore.shared.preset(withId: $0) }
    }
    public var hasPendingSavedWaveChanges: Bool {
        activeSavedWaveId != nil && tasteTracker.hasPendingStyleDrift
    }

    private var toastDismissTask: Task<Void, Never>? = nil
    private var waveStartTask: Task<Void, Never>? = nil
    private var lastEmptyMoreTracksAt: Date? = nil

    private init() {
        installAudioEngineHooks()
    }

    public var displayedWaveTracks: [YMTrack] {
        let engine = AudioPlayerEngine.shared
        if engine.isWaveMode && !engine.queue.isEmpty {
            return engine.queue
        }
        return waveTracks
    }

    public func installAudioEngineHooks() {
        let engine = AudioPlayerEngine.shared
        engine.onQueueNeedsMoreTracks = { [weak self] in
            Task { @MainActor in
                await self?.loadMoreTracks()
            }
        }

        engine.onStartCustomWaveRequested = { [weak self] context, vibe in
            Task { @MainActor in
                guard let self else { return }
                let shouldPreserveSaved = (self.activeSavedWaveId != nil && context == AudioPlayerEngine.shared.activeWaveContext)
                self.startWave(
                    context: context,
                    vibe: vibe ?? .defaultWave,
                    preserveSavedWaveId: shouldPreserveSaved
                )
            }
        }

        engine.onWaveTrackOutcome = { [weak self] track, outcome in
            self?.tasteTracker.recordOutcome(outcome, for: track)
        }
    }

    public func loadDashboardStationsIfNeeded() async {
        guard dashboardStations.isEmpty && !isLoadingDashboard else { return }
        isLoadingDashboard = true
        let fetched = await RotorService.shared.fetchRecommendedWaves()
        self.dashboardStations = fetched
        self.isLoadingDashboard = false
    }

    public func startSavedWave(_ preset: SavedWavePreset) {
        let context = YMWaveContext.forSavedWave(preset)
        activeSavedWaveId = preset.id
        tasteTracker.beginSessionFromPreset(preset, context: context)
        startWaveInternal(
            context: context,
            vibe: preset.vibe,
            excludedTrackIds: Set(preset.excludedTrackIds)
        )
    }

    public func startWave(
        context: YMWaveContext,
        vibe: YMWaveVibePreset,
        preserveSavedWaveId: Bool = false
    ) {
        if preserveSavedWaveId && activeSavedWaveId != nil {
            tasteTracker.recordVibeChange(vibe)
            let excluded = Set(activeSavedWave?.excludedTrackIds ?? tasteTracker.currentExcludedTrackIds)
            startWaveInternal(context: context, vibe: vibe, excludedTrackIds: excluded)
        } else {
            activeSavedWaveId = nil
            tasteTracker.beginFreshSession(context: context, vibe: vibe)
            startWaveInternal(context: context, vibe: vibe, excludedTrackIds: [])
        }
    }

    private func startWaveInternal(
        context: YMWaveContext,
        vibe: YMWaveVibePreset,
        excludedTrackIds: Set<String>
    ) {
        waveStartTask?.cancel()
        isLoadingWave = true
        errorMessage = nil
        lastEmptyMoreTracksAt = nil

        waveStartTask = Task {
            do {
                let initialTracks = try await RotorService.shared.startWave(
                    context: context,
                    vibe: vibe,
                    excludedTrackIds: excludedTrackIds
                )
                guard !Task.isCancelled else { return }
                self.waveTracks = initialTracks
                self.isLoadingWave = false
                let engine = AudioPlayerEngine.shared
                engine.activeWaveContext = context
                engine.activeWaveVibe = vibe
                engine.isWaveMode = true
                engine.setQueue(initialTracks, startingAt: 0)
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoadingWave = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func buildCurrentSnapshotCandidate() -> WaveSnapshotCandidate {
        let engine = AudioPlayerEngine.shared
        return tasteTracker.buildCandidateSnapshot(
            currentTrack: engine.currentTrack,
            queue: engine.queue,
            currentIndex: engine.currentIndex,
            context: engine.activeWaveContext,
            vibe: engine.activeWaveVibe
        )
    }

    public func markSavedWaveSynced(_ preset: SavedWavePreset) {
        let context = YMWaveContext.forSavedWave(preset)
        activeSavedWaveId = preset.id
        let engine = AudioPlayerEngine.shared
        if engine.isWaveMode {
            engine.activeWaveContext = context
            engine.activeWaveVibe = preset.vibe
        }
        tasteTracker.beginSessionFromPreset(preset, context: context)
    }

    public func clearActiveSavedWave() {
        activeSavedWaveId = nil
        tasteTracker.detachBaselinePreset()
    }

    public func loadMoreTracks() async {
        let currentList = displayedWaveTracks
        guard !isLoadingMoreWave, let lastTrack = currentList.last else { return }

        // Short cooldown (2 seconds) if server returned an empty batch, avoiding scroll spam
        if let lastEmpty = lastEmptyMoreTracksAt, Date().timeIntervalSince(lastEmpty) < 2.0 {
            return
        }

        isLoadingMoreWave = true
        defer { isLoadingMoreWave = false }

        do {
            let queueIds = currentList.suffix(25).map(\.rotorTrackIdentifier)
            let nextBatch = try await RotorService.shared.fetchNextBatch(
                lastTrackId: lastTrack.rotorTrackIdentifier,
                queueHistory: queueIds
            )
            if nextBatch.isEmpty {
                lastEmptyMoreTracksAt = Date()
            } else {
                lastEmptyMoreTracksAt = nil
                let engine = AudioPlayerEngine.shared
                if engine.isWaveMode {
                    engine.appendToQueue(nextBatch)
                    waveTracks = engine.queue
                } else {
                    waveTracks.append(contentsOf: nextBatch)
                }
            }
        } catch {
            print("[WaveSessionController] Error loading more wave tracks: \(error)")
        }
    }

    public func showToast(_ message: String) {
        toastDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            toastMessage = message
        }
        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                self.toastMessage = nil
            }
        }
    }
}

// MARK: - Modern Monolithic "Моя волна" View

/// Modern, monolithic "Моя волна" hub.
/// Combines an atmospheric glass Hero Stage with a single unified adaptive grid for
/// the base wave, mood/tempo modifiers, and personalized Rotor dashboard stations,
/// plus on-demand full genre catalog search and infinite track queue.
/// Does NOT auto-play on navigation.
public struct MyWaveView: View {
    @UIState private var waveController = WaveSessionController.shared
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var windowState = WindowState.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    @UIState private var authService = AuthService.shared
    @UIState private var rotorDiagnosticsStore = RotorDiagnosticsStore.shared
    @UIState private var savedWavesStore = SavedWavePresetStore.shared

    @UIState private var selectedFilter: YMWaveCategoryFilter = .forYou
    @UIState private var isCatalogSheetPresented = false
    @UIState private var activeSaveSheetMode: SaveWaveSheetMode? = nil
    @UIState private var presetPendingDelete: SavedWavePreset? = nil
    @UIState private var isScrolled: Bool = false
    @Namespace private var filterTabNamespace

    private let rotorService = RotorService.shared

    public init() {}

    private var displayedWaveTracks: [YMTrack] {
        waveController.displayedWaveTracks
    }

    private var unifiedItems: [YMUnifiedWaveItem] {
        YMUnifiedWaveItem.items(for: selectedFilter, dashboardStations: waveController.dashboardStations)
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 22) {
                // 1. Atmospheric Hero Stage (Header + Active Filter Chips + Glass Stage Card)
                heroStageSection

                // Subscription notice (if authenticated without active Plus)
                if let user = authService.currentUser, !user.hasActiveSubscription {
                    subscriptionNoticeBanner
                }

                // Tuning / Wave Feedback Toast
                if let toast = waveController.toastMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundColor(YMTheme.accent)
                            .font(.system(size: 12, weight: .bold))
                        Text(toast)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(YMTheme.fg)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(YMTheme.surface)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(YMTheme.border, lineWidth: 1))
                            .shadow(color: YMTheme.shadowColor, radius: 8, y: 2)
                    )
                    .padding(.horizontal, windowState.isMiniWidth ? 16 : 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Error Banner
                if let error = waveController.errorMessage {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Ошибка загрузки волны: \(error)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Повторить") {
                            waveController.startWave(context: audioEngine.activeWaveContext, vibe: audioEngine.activeWaveVibe)
                        }
                        .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 28))
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.orange.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
                    )
                    .padding(.horizontal, windowState.isMiniWidth ? 16 : 24)
                }

                // 2. Saved Waves Snapshots (renders only when non-empty)
                if !savedWavesStore.presets.isEmpty {
                    savedWavesSection
                }

                // 3. Unified Adaptive Block: "Поток и настроение"
                unifiedWaveHubSection

                // 4. Upcoming Queue: "Далее в волне"
                upcomingQueueSection
            }
            .padding(.bottom, 80)
            .background(alignment: .top) {
                if #unavailable(macOS 15.0) {
                    YMScrollTopSentinel(
                        coordinateSpaceName: "mywave_scroll",
                        threshold: 64,
                        isScrolled: $isScrolled
                    )
                }
            }
        }
        .ymTrackScrollOffset(threshold: 64, isScrolled: $isScrolled)
        .coordinateSpace(name: "mywave_scroll")
        .overlay(alignment: .top) {
            YMStickyTopBar(
                title: "Моя волна",
                showLiveDot: audioEngine.isWaveMode,
                isVisible: isScrolled
            )
        }
        .ymScreenBackground()
        .sheet(isPresented: $isCatalogSheetPresented) {
            AllCatalogWavesSheet(
                rotorService: rotorService,
                activeContextSeeds: audioEngine.activeWaveContext.seeds,
                onSelectStation: { station in
                    isCatalogSheetPresented = false
                    waveController.startWave(
                        context: station.toWaveContext(),
                        vibe: audioEngine.activeWaveVibe,
                        preserveSavedWaveId: false
                    )
                    waveController.showToast("Запущена волна «\(station.title)»")
                }
            )
        }
        .sheet(item: $activeSaveSheetMode) { mode in
            SaveWavePresetSheet(
                mode: mode,
                onDismiss: {
                    activeSaveSheetMode = nil
                },
                onCompleted: { result in
                    activeSaveSheetMode = nil
                    switch result {
                    case .created(let created):
                        waveController.markSavedWaveSynced(created)
                        waveController.showToast("Волна «\(created.name)» сохранена")
                    case .overwritten(let updated):
                        waveController.markSavedWaveSynced(updated)
                        waveController.showToast("Стиль волны «\(updated.name)» обновлён")
                    case .metadataUpdated(let updated):
                        waveController.showToast("Волна «\(updated.name)» обновлена")
                    }
                }
            )
        }
        .alert(
            "Удалить сохранённую волну?",
            isPresented: Binding(
                get: { presetPendingDelete != nil },
                set: { if !$0 { presetPendingDelete = nil } }
            ),
            presenting: presetPendingDelete
        ) { target in
            Button("Удалить", role: .destructive) {
                if waveController.activeSavedWaveId == target.id {
                    waveController.clearActiveSavedWave()
                }
                savedWavesStore.deletePreset(id: target.id)
                waveController.showToast("Волна «\(target.name)» удалена")
                presetPendingDelete = nil
            }
            Button("Отмена", role: .cancel) {
                presetPendingDelete = nil
            }
        } message: { target in
            Text("Снимок волны «\(target.name)» будет удалён. Вы всегда сможете сохранить новое направление заново.")
        }
        .task {
            savedWavesStore.loadIfNeeded()
            await waveController.loadDashboardStationsIfNeeded()
        }
        .onAppear {
            savedWavesStore.loadIfNeeded()
            if audioEngine.isWaveMode && !audioEngine.queue.isEmpty {
                waveController.waveTracks = audioEngine.queue
            }
            waveController.installAudioEngineHooks()
        }
    }

    // MARK: - 1. Atmospheric Hero Stage

    @ViewBuilder
    private var heroStageSection: some View {
        let horizontalPad: CGFloat = windowState.isMiniWidth ? 16 : 24
        let activeTrack = audioEngine.isWaveMode ? audioEngine.currentTrack : nil

        VStack(alignment: .leading, spacing: 14) {
            // Compact Status Header + Removable Active Filter Chips
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    waveTitleHeader
                    Spacer(minLength: 12)
                    activeFilterChipsRow
                }

                VStack(alignment: .leading, spacing: 8) {
                    waveTitleHeader
                    if hasActiveWaveFilters {
                        activeFilterChipsRow
                    }
                }
            }

            // Central Glass Stage Card
            Group {
                if let track = activeTrack {
                    ActiveGlassStageCard(track: track, aiInsight: aiInsightText(for: track), onToast: waveController.showToast)
                } else {
                    idleGlassStageCard
                }
            }
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(YMTheme.surface.opacity(YMTheme.isLight ? 0.72 : 0.76))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(YMTheme.isLight ? 0.65 : 0.14),
                                YMTheme.border,
                                YMTheme.border.opacity(0.6)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: YMTheme.shadowColor, radius: 14, y: 5)
        }
        .padding(.horizontal, horizontalPad)
        .padding(.top, windowState.topChromeContentPadding)
        .padding(.bottom, 6)
        .ymAmbientCoverGlow(coverUri: activeTrack?.effectiveCoverUri, opacity: 0.28)
    }

    private var canSaveCurrentWave: Bool {
        audioEngine.isWaveMode && (audioEngine.currentTrack != nil || !displayedWaveTracks.isEmpty)
    }

    private var hasActiveWaveFilters: Bool {
        canSaveCurrentWave
            || waveController.activeSavedWave != nil
            || audioEngine.activeWaveContext != .myWaveDefault
            || audioEngine.activeWaveVibe != .defaultWave
    }

    @ViewBuilder
    private var waveTitleHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("Моя волна")
                    .font(.system(size: windowState.isCompactWidth ? 24 : 28, weight: .bold))
                    .foregroundStyle(YMTheme.fg)
                    .fixedSize(horizontal: true, vertical: false)

                if audioEngine.isWaveMode {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(YMTheme.accent)
                            .frame(width: 6, height: 6)
                        Text("в эфире")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(YMTheme.accent)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(YMTheme.accent.opacity(0.15)))
                }

                if waveController.isLoadingWave {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(audioEngine.activeWaveContext.subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(YMTheme.fg60)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var activeFilterChipsRow: some View {
        HStack(spacing: 8) {
            if let activePreset = waveController.activeSavedWave {
                removableFilterChip(title: activePreset.name, icon: activePreset.icon.rawValue) {
                    waveController.startWave(
                        context: .myWaveDefault,
                        vibe: .defaultWave,
                        preserveSavedWaveId: false
                    )
                    waveController.showToast("Возврат к базовой «Моей волне»")
                }
            } else if audioEngine.activeWaveContext != .myWaveDefault {
                removableFilterChip(title: audioEngine.activeWaveContext.title, icon: "waveform") {
                    waveController.startWave(context: .myWaveDefault, vibe: audioEngine.activeWaveVibe)
                    waveController.showToast("Возврат к базовой «Моей волне»")
                }
            }

            if audioEngine.activeWaveVibe != .defaultWave {
                removableFilterChip(title: audioEngine.activeWaveVibe.title, icon: audioEngine.activeWaveVibe.iconName) {
                    let preserve = (waveController.activeSavedWaveId != nil)
                    waveController.startWave(
                        context: audioEngine.activeWaveContext,
                        vibe: .defaultWave,
                        preserveSavedWaveId: preserve
                    )
                    waveController.showToast("Сброс характера звучания")
                }
            }

            if canSaveCurrentWave {
                waveSnapshotActionButton
            }
        }
    }

    @ViewBuilder
    private var waveSnapshotActionButton: some View {
        if let activePreset = waveController.activeSavedWave {
            if waveController.hasPendingSavedWaveChanges {
                Button {
                    let candidate = waveController.buildCurrentSnapshotCandidate()
                    activeSaveSheetMode = .updateOrFork(existing: activePreset, candidate: candidate)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10.5, weight: .bold))
                        Text("Обновить «\(activePreset.name)»")
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(YMTheme.accentFill)
                    )
                }
                .buttonStyle(.plain)
                .help("Перезаписать стиль сохранённой волны текущим направлением или сохранить как новую")
            } else {
                Button {
                    let candidate = waveController.buildCurrentSnapshotCandidate()
                    activeSaveSheetMode = .updateOrFork(existing: activePreset, candidate: candidate)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(YMTheme.accent)
                        Text("Настроить волну")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(YMTheme.fg80)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(YMTheme.surfaceComponent)
                            .overlay(Capsule(style: .continuous).strokeBorder(YMTheme.border, lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .help("Переименовать, просмотреть якорные треки или обновить сохранённую волну")
            }
        } else {
            Button {
                let candidate = waveController.buildCurrentSnapshotCandidate()
                activeSaveSheetMode = .createNew(candidate: candidate)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(YMTheme.accent)
                    Text("Сохранить волну")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(YMTheme.fg)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(YMTheme.surfaceComponent)
                        .overlay(Capsule(style: .continuous).strokeBorder(YMTheme.border, lineWidth: 1))
                )
            }
            .buttonStyle(.plain)
            .help("Сохранить текущее направление волны под собственным названием")
        }
    }

    @ViewBuilder
    private func removableFilterChip(title: String, icon: String, onRemove: @escaping () -> Void) -> some View {
        Button(action: onRemove) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(YMTheme.accent)

                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(YMTheme.fg)
                    .lineLimit(1)

                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(YMTheme.fg60)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(YMTheme.surfaceComponent)
                    .overlay(Capsule(style: .continuous).strokeBorder(YMTheme.accent.opacity(0.32), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .help("Сбросить фильтр «\(title)»")
    }

    // MARK: - Glass Stage Card (Idle)

    @ViewBuilder
    private var idleGlassStageCard: some View {
        if windowState.isMiniWidth {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    idleWaveEmblem(size: 50, iconSize: 21)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Волна готова к запуску")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(YMTheme.fg)

                        Text("Нажмите кнопку или выберите настроение ниже")
                            .font(.system(size: 12))
                            .foregroundStyle(YMTheme.fg60)
                    }
                }

                Button {
                    waveController.startWave(context: audioEngine.activeWaveContext, vibe: audioEngine.activeWaveVibe)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Запустить Мою волну")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 36))
            }
            .padding(14)
        } else {
            HStack(spacing: 16) {
                idleWaveEmblem(size: 60, iconSize: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Волна готова к запуску")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(YMTheme.fg)

                    Text("Персональный бесконечный поток рекомендаций под ваш вкус и настроение")
                        .font(.system(size: 12.5))
                        .foregroundStyle(YMTheme.fg60)
                }

                Spacer(minLength: 12)

                Button {
                    waveController.startWave(context: audioEngine.activeWaveContext, vibe: audioEngine.activeWaveVibe)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Запустить Мою волну")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
                .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 38))
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private func idleWaveEmblem(size: CGFloat, iconSize: CGFloat) -> some View {
        YMPulsingWaveEmblem(size: size, iconSize: iconSize)
    }

    @ViewBuilder
    private var subscriptionNoticeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundColor(YMTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Требуется подписка Яндекс Плюс")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YMTheme.fg)
                Text("Для прослушивания Моей волны необходим активный Плюс")
                    .font(.system(size: 11))
                    .foregroundStyle(YMTheme.fg60)
            }
            Spacer()
            Button("Оформить") {
                if let url = URL(string: "https://plus.yandex.ru/") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 28))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(YMTheme.surfaceComponent)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(YMTheme.border, lineWidth: 1))
        )
        .padding(.horizontal, windowState.isMiniWidth ? 16 : 24)
    }

    // MARK: - 2. Saved Waves Section ("Сохранённые волны")

    @ViewBuilder
    private var savedWavesSection: some View {
        let horizontalPad: CGFloat = windowState.isMiniWidth ? 16 : 24
        let columns = [
            GridItem(
                .adaptive(
                    minimum: windowState.isMiniWidth ? 145 : 170,
                    maximum: 230
                ),
                spacing: 10
            )
        ]

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Сохранённые волны")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(YMTheme.fg)

                Text("\(savedWavesStore.presets.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(YMTheme.fg60)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(YMTheme.surfaceComponent))

                Spacer()
            }
            .padding(.horizontal, horizontalPad)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(savedWavesStore.presets) { preset in
                    let isActive = waveController.activeSavedWaveId == preset.id
                    let accent = Self.color(fromHex: preset.accentHex) ?? YMTheme.accent
                    SavedWaveCard(
                        preset: preset,
                        isActive: isActive,
                        hasDrift: isActive && waveController.hasPendingSavedWaveChanges,
                        canOverwriteWithCurrentWave: canSaveCurrentWave,
                        accentColor: accent,
                        onLaunch: {
                            waveController.startSavedWave(preset)
                            waveController.showToast("Запущена волна «\(preset.name)»")
                        },
                        onOverwrite: {
                            let candidate = waveController.buildCurrentSnapshotCandidate()
                            activeSaveSheetMode = .updateOrFork(existing: preset, candidate: candidate)
                        },
                        onEditMetadata: {
                            activeSaveSheetMode = .editMetadata(existing: preset)
                        },
                        onDelete: {
                            presetPendingDelete = preset
                        }
                    )
                }
            }
            .padding(.horizontal, horizontalPad)
        }
    }

    // MARK: - 3. Unified Adaptive Block ("Поток и настроение")

    @ViewBuilder
    private var unifiedWaveHubSection: some View {
        let horizontalPad: CGFloat = windowState.isMiniWidth ? 16 : 24
        let columns = [
            GridItem(
                .adaptive(
                    minimum: windowState.isMiniWidth ? 145 : 170,
                    maximum: 230
                ),
                spacing: 10
            )
        ]

        VStack(alignment: .leading, spacing: 14) {
            // Section Header + Compact Segmented Filter + "+ Все жанры"
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Поток и настроение")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(YMTheme.fg)
                        .fixedSize(horizontal: true, vertical: false)

                    categorySegmentedControl(compact: false, scope: "wide")

                    Spacer(minLength: 8)

                    allGenresButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center) {
                        Text("Поток и настроение")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(YMTheme.fg)

                        Spacer()

                        allGenresButton
                    }

                    categorySegmentedControl(compact: windowState.isMiniWidth, scope: "stacked")
                }
            }
            .padding(.horizontal, horizontalPad)

            // Single Adaptive Grid of Unified Wave Cards
            if waveController.isLoadingDashboard && waveController.dashboardStations.isEmpty && selectedFilter == .genresAndArtists {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Подбираем персональные волны...")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg40)
                }
                .padding(.horizontal, horizontalPad)
                .padding(.vertical, 12)
            } else if unifiedItems.isEmpty {
                HStack(spacing: 12) {
                    Text("Персональные жанры пока не загружены.")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg60)
                    Button("Открыть все жанры") {
                        isCatalogSheetPresented = true
                    }
                    .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 28))
                }
                .padding(.horizontal, horizontalPad)
                .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(unifiedItems) { item in
                        UnifiedWaveItemCard(
                            item: item,
                            isActive: isItemActive(item),
                            accentColor: accentColor(for: item)
                        ) {
                            handleUnifiedItemTap(item)
                        }
                    }
                }
                .padding(.horizontal, horizontalPad)
            }
        }
    }

    @ViewBuilder
    private func categorySegmentedControl(compact: Bool, scope: String) -> some View {
        HStack(spacing: 4) {
            ForEach(YMWaveCategoryFilter.allCases) { filter in
                let isSelected = selectedFilter == filter
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        selectedFilter = filter
                    }
                } label: {
                    Text(compact ? filter.compactTitle : filter.title)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.black : YMTheme.fg80)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(YMTheme.accentFill)
                                    .matchedGeometryEffect(id: "wave_filter_capsule_\(scope)", in: filterTabNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(YMTheme.surfaceComponent)
                .overlay(Capsule(style: .continuous).strokeBorder(YMTheme.border, lineWidth: 1))
        )
    }

    @ViewBuilder
    private var allGenresButton: some View {
        Button {
            isCatalogSheetPresented = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                Text("Все жанры")
                    .font(.system(size: 11.5, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(YMTheme.fg80)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(YMTheme.surfaceComponent)
                    .overlay(Capsule(style: .continuous).strokeBorder(YMTheme.border, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .help("Открыть полный каталог жанров и волн Яндекс Музыки")
    }

    private func isItemActive(_ item: YMUnifiedWaveItem) -> Bool {
        switch item {
        case .baseWave:
            return audioEngine.isWaveMode
                && audioEngine.activeWaveContext == .myWaveDefault
                && audioEngine.activeWaveVibe == .defaultWave
        case .vibe(let preset):
            return audioEngine.activeWaveVibe == preset
        case .station(let station):
            return waveController.activeSavedWaveId == nil
                && audioEngine.isWaveMode
                && audioEngine.activeWaveContext.seeds.contains(station.id)
        }
    }

    private func handleUnifiedItemTap(_ item: YMUnifiedWaveItem) {
        switch item {
        case .baseWave:
            waveController.startWave(
                context: .myWaveDefault,
                vibe: .defaultWave,
                preserveSavedWaveId: false
            )
            waveController.showToast("Запущена базовая «Моя волна»")

        case .station(let station):
            let context = station.toWaveContext()
            waveController.startWave(
                context: context,
                vibe: audioEngine.activeWaveVibe,
                preserveSavedWaveId: false
            )
            if audioEngine.activeWaveVibe != .defaultWave {
                waveController.showToast("Волна «\(station.title)» • \(audioEngine.activeWaveVibe.title)")
            } else {
                waveController.showToast("Запущена волна «\(station.title)»")
            }

        case .vibe(let preset):
            let nextVibe: YMWaveVibePreset = (audioEngine.activeWaveVibe == preset) ? .defaultWave : preset
            let preserveSaved = (waveController.activeSavedWaveId != nil)
            waveController.startWave(
                context: audioEngine.activeWaveContext,
                vibe: nextVibe,
                preserveSavedWaveId: preserveSaved
            )
            if nextVibe == .defaultWave {
                waveController.showToast("Характер звучания сброшен на «По умолчанию»")
            } else if audioEngine.activeWaveContext != .myWaveDefault {
                waveController.showToast("«\(audioEngine.activeWaveContext.title)» • \(nextVibe.title)")
            } else {
                waveController.showToast("Характер волны: \(nextVibe.title)")
            }
        }
    }

    private func accentColor(for item: YMUnifiedWaveItem) -> Color {
        switch item {
        case .baseWave:
            return YMTheme.accent
        case .vibe(let preset):
            return vibeColor(for: preset)
        case .station(let station):
            if let hex = station.accentHex, let parsed = Self.color(fromHex: hex) {
                return parsed
            }
            switch station.type.lowercased() {
            case "genre": return Color(red: 112 / 255, green: 146 / 255, blue: 228 / 255)
            case "mood": return Color(red: 230 / 255, green: 138 / 255, blue: 76 / 255)
            case "activity": return Color(red: 76 / 255, green: 184 / 255, blue: 146 / 255)
            case "epoch": return Color(red: 178 / 255, green: 126 / 255, blue: 218 / 255)
            case "artist": return YMTheme.accent
            default: return YMTheme.accent
            }
        }
    }

    private func vibeColor(for preset: YMWaveVibePreset) -> Color {
        switch preset {
        case .defaultWave: return YMTheme.accent.opacity(0.92)
        case .energetic: return YMTheme.isLight
            ? Color(red: 36 / 255, green: 148 / 255, blue: 112 / 255)
            : Color(red: 72 / 255, green: 188 / 255, blue: 146 / 255)
        case .unfamiliar: return YMTheme.isLight
            ? Color(red: 196 / 255, green: 118 / 255, blue: 42 / 255)
            : Color(red: 228 / 255, green: 154 / 255, blue: 72 / 255)
        case .familiar: return YMTheme.accent.opacity(0.90)
        case .popular: return YMTheme.isLight
            ? Color(red: 196 / 255, green: 76 / 255, blue: 86 / 255)
            : Color(red: 224 / 255, green: 106 / 255, blue: 114 / 255)
        case .calm: return YMTheme.isLight
            ? Color(red: 124 / 255, green: 92 / 255, blue: 186 / 255)
            : Color(red: 164 / 255, green: 132 / 255, blue: 224 / 255)
        case .joyful: return YMTheme.isLight
            ? Color(red: 204 / 255, green: 138 / 255, blue: 22 / 255)
            : Color(red: 245 / 255, green: 190 / 255, blue: 72 / 255)
        case .sad: return YMTheme.isLight
            ? Color(red: 76 / 255, green: 118 / 255, blue: 176 / 255)
            : Color(red: 118 / 255, green: 164 / 255, blue: 224 / 255)
        case .russian: return YMTheme.isLight
            ? Color(red: 182 / 255, green: 84 / 255, blue: 118 / 255)
            : Color(red: 222 / 255, green: 122 / 255, blue: 156 / 255)
        case .foreign: return YMTheme.isLight
            ? Color(red: 52 / 255, green: 132 / 255, blue: 176 / 255)
            : Color(red: 98 / 255, green: 178 / 255, blue: 224 / 255)
        case .focus: return YMTheme.isLight
            ? Color(red: 64 / 255, green: 138 / 255, blue: 132 / 255)
            : Color(red: 106 / 255, green: 192 / 255, blue: 184 / 255)
        case .workout: return YMTheme.isLight
            ? Color(red: 198 / 255, green: 94 / 255, blue: 56 / 255)
            : Color(red: 236 / 255, green: 132 / 255, blue: 88 / 255)
        }
    }

    // MARK: - 3. Upcoming Queue Section

    @ViewBuilder
    private var upcomingQueueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Далее в волне")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(YMTheme.fg)

                    Text("Треки, подобранные алгоритмом на основе ваших предпочтений")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg40)
                }

                Spacer()

                if waveController.isLoadingMoreWave {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding(.horizontal, windowState.isMiniWidth ? 16 : 24)

            if displayedWaveTracks.isEmpty && waveController.isLoadingWave {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.1)
                    Text("Подбираем музыку для вашей волны...")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg40)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else if !displayedWaveTracks.isEmpty {
                TrackTableView(
                    tracks: displayedWaveTracks,
                    onPlayTrack: { track in
                        if let idx = displayedWaveTracks.firstIndex(where: { $0.id == track.id }) {
                            audioEngine.playTrack(at: idx)
                        }
                    },
                    onLoadMore: {
                        Task {
                            await waveController.loadMoreTracks()
                        }
                    }
                )
                .padding(.horizontal, windowState.isMiniWidth ? 8 : 14)
            }
        }
    }

    // MARK: - AI Context Insights

    private func aiInsightText(for track: YMTrack) -> String {
        if let dynamicInsight = rotorDiagnosticsStore.insight(for: track.id)?.formattedInsight {
            return dynamicInsight
        }

        switch audioEngine.activeWaveVibe {
        case .energetic:
            return "Бодрый ритм под настроение"
        case .calm:
            return "Спокойная атмосфера для отдыха"
        case .unfamiliar:
            return "Свежее открытие на основе вкусов"
        case .familiar:
            return "Проверенный трек из любимых"
        case .popular:
            return "Популярный трек в Яндекс Музыке"
        case .joyful:
            return "Лёгкий и жизнерадостный настрой"
        case .sad:
            return "Глубокое меланхоличное звучание"
        case .russian:
            return "Подборка на русском языке"
        case .foreign:
            return "Подборка зарубежной музыки"
        case .focus:
            return "Сбалансированный фон для работы и фокуса"
        case .workout:
            return "Драйвовый темп для тренировки"
        case .defaultWave:
            return "Поток рекомендаций Моей волны"
        }
    }

    fileprivate static func color(fromHex hex: String) -> Color? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        let r = Double((value & 0xFF0000) >> 16) / 255.0
        let g = Double((value & 0x00FF00) >> 8) / 255.0
        let b = Double(value & 0x0000FF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Unified Wave Item Card (Clean Single-Layer Hover)

private struct UnifiedWaveCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SavedWaveCard: View {
    let preset: SavedWavePreset
    let isActive: Bool
    let hasDrift: Bool
    let canOverwriteWithCurrentWave: Bool
    let accentColor: Color
    let onLaunch: () -> Void
    let onOverwrite: () -> Void
    let onEditMetadata: () -> Void
    let onDelete: () -> Void

    @UIState private var isHovered = false

    var body: some View {
        Button(action: onLaunch) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accentColor.opacity(isActive ? 0.28 : (YMTheme.isLight ? 0.16 : 0.22)))
                        .frame(width: 34, height: 34)

                    if let coverUri = preset.primaryCoverUri, !coverUri.isEmpty {
                        CachedCoverImage(
                            coverUri: coverUri,
                            size: .small,
                            displaySize: 34,
                            cornerRadius: 8
                        )
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.42))
                            .frame(width: 34, height: 34)
                        Image(systemName: preset.icon.rawValue)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: preset.icon.rawValue)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isActive ? YMTheme.accent : accentColor)
                    }
                }
                .frame(width: 34, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.system(size: 12.5, weight: isActive ? .bold : .semibold))
                        .foregroundStyle(isActive ? YMTheme.accent : YMTheme.fg)
                        .lineLimit(1)

                    Text(preset.styleSummary)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(YMTheme.fg40)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isActive {
                    HStack(spacing: 4) {
                        if hasDrift {
                            Text("изм.")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(YMTheme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(YMTheme.accent.opacity(0.16)))
                        }
                        Circle()
                            .fill(YMTheme.accent)
                            .frame(width: 6, height: 6)
                    }
                    .help(hasDrift ? "Стиль сессии изменился — нажмите «Обновить»" : "Волна активна")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(YMTheme.surface)
                    .overlay(
                        LinearGradient(
                            colors: [
                                accentColor.opacity(isActive ? 0.18 : (isHovered ? 0.13 : (YMTheme.isLight ? 0.07 : 0.09))),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay(
                        Color.white.opacity(isHovered ? (YMTheme.isLight ? 0.20 : 0.035) : 0)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isActive ? YMTheme.accent.opacity(0.60) : (isHovered ? YMTheme.borderHover : YMTheme.border),
                        lineWidth: 1
                    )
            )
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(UnifiedWaveCardButtonStyle())
        .onHover { inside in
            if inside && TrackHoverManager.shared.isScrollSuppressed { return }
            if isHovered != inside { isHovered = inside }
        }
        .onDisappear {
            if isHovered { isHovered = false }
        }
        .contextMenu {
            Button("Запустить волну", action: onLaunch)
            if canOverwriteWithCurrentWave {
                Button("Перезаписать текущим стилем...", action: onOverwrite)
            }
            Button("Изменить название и иконку...", action: onEditMetadata)
            Divider()
            Button("Удалить волну", role: .destructive, action: onDelete)
        }
        .help(
            hasDrift
                ? "\(preset.styleSummary) • Есть несохранённые изменения стиля"
                : preset.styleSummary
        )
    }
}

private struct UnifiedWaveItemCard: View {
    let item: YMUnifiedWaveItem
    let isActive: Bool
    let accentColor: Color
    let action: () -> Void

    @UIState private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accentColor.opacity(isActive ? 0.28 : (YMTheme.isLight ? 0.16 : 0.22)))
                        .frame(width: 34, height: 34)

                    if let iconUrl = item.iconUrl, !iconUrl.isEmpty {
                        CachedCoverImage(
                            coverUri: iconUrl,
                            size: .small,
                            displaySize: 34,
                            cornerRadius: 8
                        )
                    } else {
                        Image(systemName: item.iconName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isActive ? YMTheme.accent : accentColor)
                    }
                }
                .frame(width: 34, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: isActive ? .bold : .semibold))
                        .foregroundStyle(isActive ? YMTheme.accent : YMTheme.fg)
                        .lineLimit(1)

                    Text(item.badgeText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(YMTheme.fg40)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isActive {
                    Circle()
                        .fill(YMTheme.accent)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(YMTheme.surface)
                    .overlay(
                        LinearGradient(
                            colors: [
                                accentColor.opacity(isActive ? 0.18 : (isHovered ? 0.13 : (YMTheme.isLight ? 0.07 : 0.09))),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay(
                        Color.white.opacity(isHovered ? (YMTheme.isLight ? 0.20 : 0.035) : 0)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isActive ? YMTheme.accent.opacity(0.60) : (isHovered ? YMTheme.borderHover : YMTheme.border),
                        lineWidth: 1
                    )
            )
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(UnifiedWaveCardButtonStyle())
        .onHover { inside in
            if inside && TrackHoverManager.shared.isScrollSuppressed { return }
            if isHovered != inside { isHovered = inside }
        }
        .onDisappear {
            if isHovered { isHovered = false }
        }
        .help(item.subtitle)
    }
}

// MARK: - On-Demand Full Catalog Sheet ("+ Все жанры")

private struct AllCatalogWavesSheet: View {
    let rotorService: RotorService
    let activeContextSeeds: [String]
    let onSelectStation: (YMPersonalWaveStation) -> Void

    @Environment(\.dismiss) private var dismiss
    @UIState private var catalogStations: [YMPersonalWaveStation] = []
    @UIState private var searchQuery: String = ""
    @UIState private var isLoading = true
    @UIState private var loadError: String? = nil

    private var filteredStations: [YMPersonalWaveStation] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return catalogStations }
        return catalogStations.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.categoryLabel.localizedCaseInsensitiveContains(q)
                || $0.tag.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Все жанры и волны")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(YMTheme.fg)
                    Text("Полный каталог станций Rotor API")
                        .font(.system(size: 11.5))
                        .foregroundStyle(YMTheme.fg60)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(YMTheme.fg80)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(YMTheme.surfaceComponent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(YMTheme.fg40)

                TextField("Найти жанр, настроение или эпоху...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(YMTheme.fg)

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(YMTheme.fg40)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(YMTheme.surfaceComponent)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(YMTheme.border, lineWidth: 1))
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()
                .overlay(YMTheme.border)

            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Загрузка каталога волн...")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(YMTheme.fg)
                    Button("Повторить") {
                        Task {
                            await loadCatalog()
                        }
                    }
                    .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 28))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredStations.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(YMTheme.fg40)
                    Text("Ничего не найдено")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(YMTheme.fg)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(filteredStations) { station in
                            let item = YMUnifiedWaveItem.station(station)
                            let accent = station.accentHex.flatMap(MyWaveView.color(fromHex:)) ?? YMTheme.accent
                            UnifiedWaveItemCard(
                                item: item,
                                isActive: activeContextSeeds.contains(station.id),
                                accentColor: accent
                            ) {
                                onSelectStation(station)
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 560, height: 480)
        .ymScreenBackground()
        .task {
            await loadCatalog()
        }
    }

    private func loadCatalog() async {
        isLoading = true
        loadError = nil
        let stations = await rotorService.fetchAllCatalogWaves()
        if stations.isEmpty {
            self.loadError = "Не удалось загрузить каталог станций"
        } else {
            self.catalogStations = stations
        }
        self.isLoading = false
    }
}

// MARK: - Individual Artist Button for My Wave Hero Stage

private struct MyWaveHeroArtistButton: View {
    let artist: YMArtist
    let onSelect: () -> Void

    @UIState private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            Text(artist.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovered ? YMTheme.fg : YMTheme.fg60)
                .underline(isHovered)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Перейти к исполнителю: \(artist.name)")
    }
}

/// Isolated emblem for idle state — static in idle for zero CPU load with responsive hover effect.
private struct YMPulsingWaveEmblem: View {
    let size: CGFloat
    let iconSize: CGFloat
    @UIState private var isHovered: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(YMTheme.accent.opacity(isHovered ? 0.22 : 0.14))
                .frame(width: size, height: size)

            Image(systemName: "waveform.path.ecg")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(YMTheme.accent)
                .scaleEffect(isHovered ? 1.06 : 1.0)
        }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Dedicated Glass Stage Card & Controls Components

private struct StageIconButton: View {
    let systemName: String
    let color: Color
    let size: CGFloat
    var showBackground: Bool = true
    let help: String
    let action: () -> Void

    @UIState private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size <= 28 ? 12 : 13, weight: .semibold))
                .foregroundStyle(isHovered ? (color == YMTheme.fg60 || color == YMTheme.fg80 ? YMTheme.fg : color) : color)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(isHovered ? YMTheme.surfaceComponentHover : (showBackground ? YMTheme.surfaceComponent : Color.clear))
                )
                .scaleEffect(isHovered ? 1.06 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isHovered)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private struct ActiveTrackLikeButton: View {
    let track: YMTrack
    let iconButtonSize: CGFloat
    @UIState private var likesService = LikesService.shared

    var body: some View {
        let isLiked = likesService.isLiked(trackId: track.id)
        StageIconButton(
            systemName: isLiked ? "heart.fill" : "heart",
            color: isLiked ? YMTheme.heartRed : YMTheme.fg60,
            size: iconButtonSize,
            help: isLiked ? "Удалить из Мне нравится" : "Мне нравится"
        ) {
            Task {
                await likesService.toggleLike(track: track)
            }
        }
    }
}

private struct ActiveTrackControls: View {
    let track: YMTrack
    let playDiscSize: CGFloat
    let playIconSize: CGFloat
    let spacing: CGFloat
    let onToast: (String) -> Void

    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var windowState = WindowState.shared
    @UIState private var isFlameActive = false
    @UIState private var flameResetTask: Task<Void, Never>? = nil

    var body: some View {
        let iconButtonSize: CGFloat = windowState.isMiniWidth ? 28 : 32

        HStack(spacing: spacing) {
            // 1. Dislike (Less Like This)
            StageIconButton(
                systemName: "hand.thumbsdown.fill",
                color: YMTheme.fg60,
                size: iconButtonSize,
                help: "Меньше таких треков"
            ) {
                audioEngine.applyWaveTuning(.lessLikeThis)
                onToast("Меньше таких треков в волне")
            }

            // 2. Previous
            StageIconButton(
                systemName: "backward.fill",
                color: YMTheme.fg80,
                size: iconButtonSize,
                showBackground: false,
                help: "Предыдущий трек"
            ) {
                audioEngine.previous()
            }

            // 3. Signature Golden Play / Pause Disc (46x46)
            Button {
                audioEngine.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(YMTheme.accentFill)
                        .frame(width: playDiscSize, height: playDiscSize)
                        .shadow(color: YMTheme.accentFill.opacity(audioEngine.isPlaying ? 0.34 : 0.16), radius: 9, y: 2)

                    Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: playIconSize, weight: .bold))
                        .foregroundColor(Color.black)
                        .offset(x: audioEngine.isPlaying ? 0 : 1)
                }
            }
            .buttonStyle(.plain)
            .help(audioEngine.isPlaying ? "Пауза" : "Воспроизведение")

            // 4. Next
            StageIconButton(
                systemName: "forward.fill",
                color: YMTheme.fg80,
                size: iconButtonSize,
                showBackground: false,
                help: "Следующий трек"
            ) {
                audioEngine.next()
            }

            // 5. Flame (More Like This)
            StageIconButton(
                systemName: "flame.fill",
                color: isFlameActive ? Color.orange : YMTheme.accent,
                size: iconButtonSize,
                help: "Больше таких треков"
            ) {
                audioEngine.applyWaveTuning(.moreLikeThis)
                flameResetTask?.cancel()
                isFlameActive = true
                onToast("Больше треков в стиле «\(track.displayTitle)»")
                flameResetTask = Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { isFlameActive = false }
                }
            }

            // 6. Shake / Diversity ("Встряхнуть")
            StageIconButton(
                systemName: "sparkles",
                color: YMTheme.fg80,
                size: iconButtonSize,
                help: "Встряхнуть поток и добавить открытий"
            ) {
                audioEngine.applyWaveTuning(.moreDiversity)
                onToast("Перенастройка волны: добавлено больше открытий")
            }

            // 7. Like (Heart) - Isolated Observation
            ActiveTrackLikeButton(track: track, iconButtonSize: iconButtonSize)
        }
        .onDisappear {
            flameResetTask?.cancel()
            flameResetTask = nil
        }
    }
}

private struct ActiveGlassStageCard: View {
    let track: YMTrack
    let aiInsight: String
    let onToast: (String) -> Void

    @UIState private var windowState = WindowState.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    @UIState private var audioEngine = AudioPlayerEngine.shared

    var body: some View {
        if windowState.isCompactWidth {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    activeTrackCoverButton(size: 64, cornerRadius: 10, eqMaxHeight: 20)
                    activeTrackMeta
                    Spacer(minLength: 4)
                }

                ActiveTrackControls(
                    track: track,
                    playDiscSize: windowState.isMiniWidth ? 40 : 42,
                    playIconSize: 15,
                    spacing: windowState.isMiniWidth ? 8 : 12,
                    onToast: onToast
                )
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(windowState.isMiniWidth ? 12 : 16)
        } else {
            HStack(spacing: 18) {
                activeTrackCoverButton(size: 88, cornerRadius: 12, eqMaxHeight: 24)
                activeTrackMeta
                Spacer(minLength: 12)
                ActiveTrackControls(
                    track: track,
                    playDiscSize: 46,
                    playIconSize: 17,
                    spacing: 10,
                    onToast: onToast
                )
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func activeTrackCoverButton(size: CGFloat, cornerRadius: CGFloat, eqMaxHeight: CGFloat) -> some View {
        Button {
            if let album = track.albums.first {
                coordinator.navigate(to: .album(id: album.id, title: album.title))
            }
        } label: {
            ZStack {
                CachedCoverImage(
                    coverUri: track.effectiveCoverUri,
                    size: .medium,
                    displaySize: size,
                    cornerRadius: cornerRadius
                )

                if audioEngine.isPlaying {
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(Color.black.opacity(0.50))
                            .frame(width: size, height: size)

                        YMPlayingEqualizerView(
                            color: YMTheme.accent,
                            barWidth: 3,
                            maxHeight: eqMaxHeight,
                            isPlaying: true
                        )
                    }
                    .frame(width: size, height: size)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: YMTheme.shadowColor, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .help("Перейти к альбому")
    }

    @ViewBuilder
    private var activeTrackMeta: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(track.displayTitle)
                .font(.system(size: windowState.isCompactWidth ? 15 : 17, weight: .bold))
                .foregroundStyle(YMTheme.fg)
                .lineLimit(1)

            if !track.artists.isEmpty {
                let artistsToDisplay = Array(track.artists.prefix(4))
                HStack(spacing: 4) {
                    ForEach(artistsToDisplay) { artist in
                        MyWaveHeroArtistButton(artist: artist) {
                            coordinator.navigate(to: .artist(id: artist.id, name: artist.name))
                        }

                        if artist.id != artistsToDisplay.last?.id {
                            Text("•")
                                .font(.system(size: 8))
                                .foregroundStyle(YMTheme.fg40)
                        }
                    }
                }
                .clipped()
            } else {
                Text(track.artistsString)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(YMTheme.fg60)
                    .lineLimit(1)
            }

            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(YMTheme.accent)
                Text(aiInsight)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(YMTheme.fg40)
                    .lineLimit(1)
            }
            .padding(.top, 2)
        }
        .layoutPriority(1)
    }
}
