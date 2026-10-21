import SwiftUI
import Observation

enum AppTab: Hashable {
    case library
    case community
    case settings
}

enum SidebarItem: Hashable, Identifiable, CaseIterable {
    case library
    case community
    case settings

    var id: SidebarItem { self }

    var title: String {
        switch self {
        case .library: return "曲库"
        case .community: return "社区"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .library: return "music.note.list"
        case .community: return "person.3"
        case .settings: return "gearshape"
        }
    }
}

/// App-wide navigation state and import orchestration.
@Observable
@MainActor
final class AppModel {
    /// Compact layout: selected tab.
    var selectedTab: AppTab = .library
    /// Regular layout: selected sidebar entry.
    var sidebarSelection: SidebarItem? = .library
    /// Regular layout: score shown in the detail column.
    var selectedScoreID: UUID?
    /// Compact layout: navigation path of the library tab (score ids).
    var libraryPath: [UUID] = []

    let importCoordinator = ImportCoordinator()

    /// Opens a score in whichever layout is active.
    func open(scoreID: UUID) {
        selectedTab = .library
        sidebarSelection = .library
        selectedScoreID = scoreID
        libraryPath = [scoreID]
    }

    /// A score was deleted: drop any navigation state pointing at it.
    func didDelete(scoreID: UUID) {
        if selectedScoreID == scoreID {
            selectedScoreID = nil
        }
        libraryPath.removeAll { $0 == scoreID }
    }

    /// Files opened from other apps (Files, share sheet, AirDrop...).
    func handleOpenURL(_ url: URL) {
        guard url.isFileURL else { return }
        Task {
            await importCoordinator.importFiles([url])
        }
    }
}
