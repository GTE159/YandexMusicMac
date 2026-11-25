import SwiftUI

/// Presentation mode for `SaveWavePresetSheet`.
public enum SaveWaveSheetMode: Identifiable, Sendable {
    case createNew(candidate: WaveSnapshotCandidate)
    case updateOrFork(existing: SavedWavePreset, candidate: WaveSnapshotCandidate)
    case editMetadata(existing: SavedWavePreset)

    public var id: String {
        switch self {
        case .createNew:
            return "createNew"
        case .updateOrFork(let existing, _):
            return "updateOrFork_\(existing.id.uuidString)"
        case .editMetadata(let existing):
            return "editMetadata_\(existing.id.uuidString)"
        }
    }
}

public enum SaveWaveResultAction: Sendable {
    case created(SavedWavePreset)
    case overwritten(SavedWavePreset)
    case metadataUpdated(SavedWavePreset)
}

/// Modal macOS sheet for creating, updating (overwriting / forking), or renaming a saved wave preset.
public struct SaveWavePresetSheet: View {
    public let mode: SaveWaveSheetMode
    public let onDismiss: () -> Void
    public let onCompleted: (SaveWaveResultAction) -> Void

    @UIState private var store = SavedWavePresetStore.shared
    @UIState private var name: String
    @UIState private var selectedIcon: SavedWaveIcon
    @UIState private var selectedAccentHex: String
    @UIState private var editableAnchors: [SavedWaveAnchorTrack]

    private static let accentPaletteHexes: [(hex: String, title: String)] = [
        ("#F2C12E", "Золото"),
        ("#48BC92", "Мята"),
        ("#7092E4", "Индиго"),
        ("#EE444E", "Коралл"),
        ("#A484E0", "Лаванда"),
        ("#EC8458", "Терракота")
    ]

    public init(
        mode: SaveWaveSheetMode,
        onDismiss: @escaping () -> Void,
        onCompleted: @escaping (SaveWaveResultAction) -> Void
    ) {
        self.mode = mode
        self.onDismiss = onDismiss
        self.onCompleted = onCompleted

        switch mode {
        case .createNew(let candidate):
            let defaultIcon: SavedWaveIcon = candidate.vibe == .focus ? .briefcase :
                (candidate.vibe == .calm ? .moon : (candidate.vibe == .workout || candidate.vibe == .energetic ? .bolt : .waveform))
            self._name = UIState(initialValue: "")
            self._selectedIcon = UIState(initialValue: defaultIcon)
            self._selectedAccentHex = UIState(initialValue: "#F2C12E")
            self._editableAnchors = UIState(initialValue: candidate.anchorTracks)

        case .updateOrFork(let existing, let candidate):
            self._name = UIState(initialValue: existing.name)
            self._selectedIcon = UIState(initialValue: existing.icon)
            self._selectedAccentHex = UIState(initialValue: existing.accentHex)
            self._editableAnchors = UIState(initialValue: candidate.anchorTracks)

        case .editMetadata(let existing):
            self._name = UIState(initialValue: existing.name)
            self._selectedIcon = UIState(initialValue: existing.icon)
            self._selectedAccentHex = UIState(initialValue: existing.accentHex)
            self._editableAnchors = UIState(initialValue: existing.anchorTracks)
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var candidate: WaveSnapshotCandidate? {
        switch mode {
        case .createNew(let c): return c
        case .updateOrFork(_, let c): return c
        case .editMetadata: return nil
        }
    }

    private var existingPreset: SavedWavePreset? {
        switch mode {
        case .createNew: return nil
        case .updateOrFork(let e, _), .editMetadata(let e): return e
        }
    }

    private var headerTitle: String {
        switch mode {
        case .createNew:
            return "Сохранить волну"
        case .updateOrFork(let existing, _):
            return "Обновить волну «\(existing.name)»"
        case .editMetadata(let existing):
            return "Настроить волну «\(existing.name)»"
        }
    }

    private var headerSubtitle: String {
        switch mode {
        case .createNew:
            return "Зафиксируйте текущее звучание и подборку для запуска в 1 клик"
        case .updateOrFork:
            return "Перезапишите сохранённый вектор новым стилем или сохраните копию"
        case .editMetadata:
            return "Измените название, иконку и цвет карточки без изменения стиля"
        }
    }

    private var resolvedAccentColor: Color {
        Self.color(fromHex: selectedAccentHex) ?? YMTheme.accent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(resolvedAccentColor.opacity(0.18))
                        .frame(width: 38, height: 38)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(resolvedAccentColor.opacity(0.40), lineWidth: 1)
                        )

                    Image(systemName: selectedIcon.rawValue)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(resolvedAccentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(YMTheme.fg)
                        .lineLimit(1)

                    Text(headerSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(YMTheme.fg60)
                        .lineLimit(2)
                }

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(YMTheme.fg60)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(YMTheme.surfaceComponent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }

            Divider()
                .overlay(YMTheme.border)

            // Name Field
            VStack(alignment: .leading, spacing: 6) {
                Text("Название")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(YMTheme.fg80)

                TextField("Например: Работа, Ночной код, Дорога", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(YMTheme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(YMTheme.borderHover, lineWidth: 1)
                            )
                    )
                    .onSubmit {
                        if !trimmedName.isEmpty {
                            submitPrimaryAction()
                        }
                    }
            }

            // Icon & Accent Color Pickers
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Оформление")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(YMTheme.fg80)

                    Spacer()

                    HStack(spacing: 8) {
                        ForEach(Self.accentPaletteHexes, id: \.hex) { swatch in
                            let swatchColor = Self.color(fromHex: swatch.hex) ?? YMTheme.accent
                            let isSelected = selectedAccentHex.caseInsensitiveCompare(swatch.hex) == .orderedSame
                            Button {
                                selectedAccentHex = swatch.hex
                            } label: {
                                Circle()
                                    .fill(swatchColor)
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.white.opacity(isSelected ? 0.95 : 0.25), lineWidth: isSelected ? 2 : 0.75)
                                    )
                                    .scaleEffect(isSelected ? 1.14 : 1.0)
                                    .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isSelected)
                            }
                            .buttonStyle(.plain)
                            .help(swatch.title)
                        }
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(SavedWaveIcon.allCases) { icon in
                        let isSelected = selectedIcon == icon
                        Button {
                            selectedIcon = icon
                        } label: {
                            Image(systemName: icon.rawValue)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(isSelected ? resolvedAccentColor : YMTheme.fg60)
                                .frame(maxWidth: .infinity)
                                .frame(height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isSelected ? resolvedAccentColor.opacity(0.18) : YMTheme.surface)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(isSelected ? resolvedAccentColor.opacity(0.55) : YMTheme.border, lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Wave DNA Snapshot Preview (only when creating or updating DNA)
            if let candidate {
                waveDNASection(candidate: candidate)
            }

            // Footer Buttons
            HStack(spacing: 10) {
                Spacer()

                Button("Отмена") {
                    onDismiss()
                }
                .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 32))

                switch mode {
                case .createNew:
                    Button("Сохранить волну") {
                        submitPrimaryAction()
                    }
                    .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 32))
                    .disabled(trimmedName.isEmpty)

                case .updateOrFork(let existing, _):
                    Button("Сохранить как новую") {
                        performCreateFromCandidate()
                    }
                    .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 32))
                    .disabled(trimmedName.isEmpty)

                    Button("Перезаписать «\(existing.name)»") {
                        submitPrimaryAction()
                    }
                    .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 32))
                    .disabled(trimmedName.isEmpty)

                case .editMetadata:
                    Button("Сохранить") {
                        submitPrimaryAction()
                    }
                    .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 32))
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(YMTheme.bg)
    }

    // MARK: - DNA Preview Block

    @ViewBuilder
    private func waveDNASection(candidate: WaveSnapshotCandidate) -> some View {
        let canRemoveLastAnchor = candidate.hasNonDefaultContext

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("ДНК волны (что сохранится)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(YMTheme.fg80)

                Spacer()

                if !candidate.baseContextTitle.isEmpty && candidate.baseContextTitle != "Моя волна" {
                    dnaPill(text: candidate.baseContextTitle, icon: "waveform")
                }

                if candidate.vibe != .defaultWave {
                    dnaPill(text: candidate.vibe.title, icon: candidate.vibe.iconName)
                }

                if !candidate.excludedTrackIds.isEmpty {
                    dnaPill(text: "−\(candidate.excludedTrackIds.count) дизлайков", icon: "hand.thumbsdown")
                }
            }

            if !editableAnchors.isEmpty {
                VStack(spacing: 6) {
                    ForEach(editableAnchors) { anchor in
                        let removeDisabled = (editableAnchors.count <= 1 && !canRemoveLastAnchor)
                        HStack(spacing: 10) {
                            CachedCoverImage(
                                coverUri: anchor.coverUri,
                                size: .small,
                                displaySize: 28,
                                cornerRadius: 5
                            )

                            VStack(alignment: .leading, spacing: 1) {
                                Text(anchor.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(YMTheme.fg)
                                    .lineLimit(1)

                                Text(anchor.artistName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(YMTheme.fg60)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 4)

                            Button {
                                editableAnchors.removeAll { $0.id == anchor.id }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(removeDisabled ? YMTheme.fg40.opacity(0.35) : YMTheme.fg60)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(YMTheme.surfaceComponent))
                            }
                            .buttonStyle(.plain)
                            .disabled(removeDisabled)
                            .help(removeDisabled ? "Должен остаться хотя бы один якорный трек" : "Убрать трек из снимка")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(YMTheme.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(YMTheme.border, lineWidth: 1)
                                )
                        )
                    }
                }
            }

            Text("Волна сохраняется как снимок. Обычное прослушивание и пропуски треков не изменят её, пока вы сами не нажмёте «Обновить».")
                .font(.caption)
                .foregroundStyle(YMTheme.fg40)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(YMTheme.surfaceComponent.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(YMTheme.border, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func dnaPill(text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(resolvedAccentColor)
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(YMTheme.fg80)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(YMTheme.surface))
    }

    // MARK: - Actions

    private func submitPrimaryAction() {
        switch mode {
        case .createNew:
            performCreateFromCandidate()

        case .updateOrFork(let existing, let candidate):
            if let updated = store.overwritePreset(
                id: existing.id,
                name: trimmedName,
                icon: selectedIcon,
                accentHex: selectedAccentHex,
                baseContextSeeds: candidate.baseContextSeeds,
                baseContextTitle: candidate.baseContextTitle,
                baseFallbackStationId: candidate.baseFallbackStationId,
                vibe: candidate.vibe,
                anchorTracks: editableAnchors,
                excludedTrackIds: candidate.excludedTrackIds
            ) {
                onCompleted(.overwritten(updated))
            }

        case .editMetadata(let existing):
            store.updateMetadata(
                id: existing.id,
                name: trimmedName,
                icon: selectedIcon,
                accentHex: selectedAccentHex
            )
            let updated = store.preset(withId: existing.id) ?? existing
            onCompleted(.metadataUpdated(updated))
        }
    }

    private func performCreateFromCandidate() {
        guard let candidate else { return }
        if let created = store.createPreset(
            name: trimmedName,
            icon: selectedIcon,
            accentHex: selectedAccentHex,
            baseContextSeeds: candidate.baseContextSeeds,
            baseContextTitle: candidate.baseContextTitle,
            baseFallbackStationId: candidate.baseFallbackStationId,
            vibe: candidate.vibe,
            anchorTracks: editableAnchors,
            excludedTrackIds: candidate.excludedTrackIds
        ) {
            onCompleted(.created(created))
        }
    }

    private static func color(fromHex hex: String) -> Color? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        let r = Double((value & 0xFF0000) >> 16) / 255.0
        let g = Double((value & 0x00FF00) >> 8) / 255.0
        let b = Double(value & 0x0000FF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}
