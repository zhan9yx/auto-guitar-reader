import Foundation
import Observation
import AGRCore

enum CommunitySortOption: String, CaseIterable, Identifiable {
    case recent
    case popular

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return "最新"
        case .popular: return "最热"
        }
    }

    var coreValue: CommunitySort {
        switch self {
        case .recent: return .recent
        case .popular: return .popular
        }
    }
}

/// Search / paging state for the community list.
@Observable
@MainActor
final class CommunityViewModel {
    static let pageSize = 20

    var query: String = ""
    var sort: CommunitySortOption = .recent

    private(set) var items: [CommunityScoreSummary] = []
    private(set) var total: Int = 0
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?
    private(set) var hasLoadedOnce = false
    /// Transient error of a row action (e.g. favoriting failed); shown in an alert.
    var actionMessage: String?

    @ObservationIgnored private var page = 1
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private weak var settings: SettingsStore?

    func attach(settings: SettingsStore) {
        self.settings = settings
    }

    var canLoadMore: Bool {
        items.count < total
    }

    /// Debounced (300 ms) reload for search-as-you-type.
    func scheduleReload() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    /// Fetches page 1 and replaces the list.
    func reload() async {
        generation += 1
        let myGeneration = generation
        isLoading = true
        isLoadingMore = false
        errorMessage = nil

        guard let client = settings?.communityClient() else {
            isLoading = false
            hasLoadedOnce = true
            errorMessage = "服务器地址无效，请在“设置”中检查。"
            return
        }

        do {
            let response = try await client.search(
                query: query.trimmed,
                sort: sort.coreValue,
                page: 1,
                pageSize: Self.pageSize
            )
            guard myGeneration == generation else { return }
            items = response.items
            total = response.total
            page = 1
            isLoading = false
            hasLoadedOnce = true
        } catch {
            guard myGeneration == generation else { return }
            items = []
            total = 0
            isLoading = false
            hasLoadedOnce = true
            errorMessage = describeError(error)
        }
    }

    /// Pagination: call when a row appears.
    func loadMoreIfNeeded(current item: CommunityScoreSummary) async {
        guard !isLoading, !isLoadingMore, canLoadMore else { return }
        guard let index = items.firstIndex(where: { $0.id == item.id }), index >= items.count - 3 else { return }
        guard let client = settings?.communityClient() else { return }

        isLoadingMore = true
        let myGeneration = generation
        let nextPage = page + 1
        do {
            let response = try await client.search(
                query: query.trimmed,
                sort: sort.coreValue,
                page: nextPage,
                pageSize: Self.pageSize
            )
            guard myGeneration == generation else { return }
            let known = Set(items.map { $0.id })
            items.append(contentsOf: response.items.filter { !known.contains($0.id) })
            total = response.total
            page = nextPage
            isLoadingMore = false
        } catch {
            guard myGeneration == generation else { return }
            isLoadingMore = false
            errorMessage = describeError(error)
        }
    }

    // MARK: Favorites

    /// Optimistic heart toggle: the row flips at once, the server's answer is authoritative, failure rolls back.
    func toggleFavorite(_ item: CommunityScoreSummary) async {
        guard let client = settings?.communityClient() else { return }
        guard let current = items.first(where: { $0.id == item.id }) else { return }
        let before = FavoriteSnapshot(summary: current)
        applyFavorite(scoreID: item.id, snapshot: before.toggled())
        do {
            let state: CommunityFavoriteState
            if before.favorited {
                state = try await client.unfavorite(scoreID: item.id)
            } else {
                state = try await client.favorite(scoreID: item.id)
            }
            applyFavorite(scoreID: item.id, snapshot: FavoriteSnapshot(state: state))
        } catch {
            applyFavorite(scoreID: item.id, snapshot: before)
            actionMessage = "收藏操作失败：\(describeError(error))"
        }
    }

    /// Applies a server-confirmed state (e.g. from the detail sheet) to the list row.
    func applyFavorite(scoreID: String, state: CommunityFavoriteState) {
        applyFavorite(scoreID: scoreID, snapshot: FavoriteSnapshot(state: state))
    }

    private func applyFavorite(scoreID: String, snapshot: FavoriteSnapshot) {
        guard let index = items.firstIndex(where: { $0.id == scoreID }) else { return }
        items[index] = items[index].applying(snapshot)
    }
}
