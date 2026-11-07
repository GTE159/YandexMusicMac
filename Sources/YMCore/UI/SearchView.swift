import SwiftUI

/// Modern, intelligent Search view featuring quick genre exploration pills,
/// artist carousels, and high-performance tracklist tables.
public struct SearchView: View {
    @UIState private var searchText = ""
    @UIState private var searchResults: [YMTrack] = []
    @UIState private var isSearching = false
    @UIState private var hasSearched = false
    @UIState private var errorMessage: String? = nil
    @UIState private var currentPage = 0
    @UIState private var canLoadMore = true
    @UIState private var isLoadingMore = false
    @UIState private var searchTask: Task<Void, Never>? = nil

    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    private let networkClient = YMNetworkClient.shared

    private let quickGenres: [String] = [
        "Рок", "Поп", "Рэп и хип-хоп", "Электроника", "Инди", "Танцевальная", "Метал", "Саундтреки", "Джаз", "Фонк"
    ]

    public init() {}

    /// Extracts unique artists from current search results for the artists carousel
    private var searchArtists: [YMArtist] {
        var seen = Set<String>()
        var artists: [YMArtist] = []
        for track in searchResults {
            for artist in track.artists {
                if !seen.contains(artist.id) {
                    seen.insert(artist.id)
                    artists.append(artist)
                }
            }
        }
        return Array(artists.prefix(12))
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search Input Header
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(YMTheme.accent)

                TextField("Треки, артисты, альбомы...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit {
                        performSearch()
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                        hasSearched = false
                        errorMessage = nil
                        currentPage = 0
                        canLoadMore = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(YMTheme.fg40)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(YMTheme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(YMTheme.border, lineWidth: 1))
            )
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 24)

            if let error = errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }

            // Content Area
            if isSearching && searchResults.isEmpty {
                VStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Ищем в Яндекс Музыке...")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searchResults.isEmpty {
                // Empty state or Quick Genres explore
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 20) {
                        if hasSearched {
                            VStack(spacing: 12) {
                                Image(systemName: "questionmark.folder")
                                    .font(.system(size: 44))
                                    .foregroundStyle(YMTheme.fg40)
                                Text("Ничего не найдено")
                                    .font(.headline)
                                    .foregroundStyle(YMTheme.fg)
                                Text("Попробуйте изменить поисковый запрос или проверить орфографию")
                                    .font(.subheadline)
                                    .foregroundStyle(YMTheme.fg60)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        } else {
                            Text("Популярные жанры и темы")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(YMTheme.fg)
                                .padding(.horizontal, 24)

                            // Quick Genre Grid
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)], spacing: 12) {
                                ForEach(quickGenres, id: \.self) { genre in
                                    Button {
                                        searchText = genre
                                        performSearch()
                                    } label: {
                                        HStack {
                                            Text(genre)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(YMTheme.fg)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 10))
                                                .foregroundStyle(YMTheme.fg40)
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(YMTheme.surface)
                                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(YMTheme.border, lineWidth: 1))
                                        )
                                        .ymCardHover(cornerRadius: 10, scale: 1.03)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                    .padding(.top, 20)
                }
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 20) {
                        // Artists Carousel if any match
                        if !searchArtists.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Исполнители")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(YMTheme.fg)
                                    .padding(.horizontal, 24)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 16) {
                                        ForEach(searchArtists) { artist in
                                            YMArtistCard(artist: artist) {
                                                coordinator.navigate(to: .artist(id: artist.id, name: artist.name))
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 8)
                                }
                            }
                        }

                        // Tracks Section
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Треки")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(YMTheme.fg)
                                .padding(.horizontal, 24)

                            TrackTableView(
                                tracks: searchResults,
                                onPlayTrack: { track in
                                    audioEngine.isWaveMode = false
                                    if let idx = searchResults.firstIndex(where: { $0.id == track.id }) {
                                        audioEngine.setQueue(searchResults, startingAt: idx)
                                    }
                                },
                                onLoadMore: {
                                    Task {
                                        await loadMoreSearchResults()
                                    }
                                }
                            )
                            .padding(.horizontal, 16)

                            if isLoadingMore {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 60)
                }
            }
        }
        .ymScreenBackground()
    }

    private func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        searchTask?.cancel()
        isSearching = true
        hasSearched = true
        errorMessage = nil
        currentPage = 0
        canLoadMore = true

        searchTask = Task {
            do {
                let results = try await networkClient.searchTracks(query: trimmed, page: 0)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.searchResults = results
                    self.isSearching = false
                    if results.count < 20 {
                        self.canLoadMore = false
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isSearching = false
                }
            }
        }
    }

    private func loadMoreSearchResults() async {
        guard canLoadMore, !isLoadingMore, !isSearching else { return }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoadingMore = true
        let nextPage = currentPage + 1

        do {
            let nextBatch = try await networkClient.searchTracks(query: trimmed, page: nextPage)
            await MainActor.run {
                if nextBatch.isEmpty {
                    self.canLoadMore = false
                } else {
                    let existingIds = Set(self.searchResults.map(\.id))
                    let uniqueNew = nextBatch.filter { !existingIds.contains($0.id) }
                    self.searchResults.append(contentsOf: uniqueNew)
                    self.currentPage = nextPage
                    if nextBatch.count < 20 {
                        self.canLoadMore = false
                    }
                }
                self.isLoadingMore = false
            }
        } catch {
            await MainActor.run {
                self.isLoadingMore = false
            }
        }
    }
}
