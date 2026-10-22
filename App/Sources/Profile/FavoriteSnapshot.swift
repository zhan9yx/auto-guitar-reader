import Foundation
import AGRCore

/// Favorite state of one score as shown in the UI; `toggled()` is the optimistic update applied before the server answers.
struct FavoriteSnapshot: Equatable, Sendable {
    var favorited: Bool
    var count: Int

    init(favorited: Bool, count: Int) {
        self.favorited = favorited
        self.count = max(0, count)
    }

    init(state: CommunityFavoriteState) {
        self.init(favorited: state.favorited, count: state.favorites)
    }

    init(summary: CommunityScoreSummary) {
        self.init(favorited: summary.favoritedByMe, count: summary.favorites)
    }

    func toggled() -> FavoriteSnapshot {
        FavoriteSnapshot(favorited: !favorited, count: favorited ? count - 1 : count + 1)
    }
}

extension CommunityScoreSummary {
    func applying(_ snapshot: FavoriteSnapshot) -> CommunityScoreSummary {
        var copy = self
        copy.favoritedByMe = snapshot.favorited
        copy.favorites = snapshot.count
        return copy
    }
}
