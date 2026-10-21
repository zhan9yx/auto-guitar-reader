import SwiftUI
import AGRCore

/// Compact width (iPhone): TabView. Regular width (iPad): three-column NavigationSplitView.
@MainActor
struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(ScoreStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        @Bindable var coordinator = appModel.importCoordinator

        Group {
            if horizontalSizeClass == .regular {
                regularLayout(appModel)
            } else {
                compactLayout(appModel)
            }
        }
        .sheet(item: $coordinator.currentDraft, onDismiss: {
            appModel.importCoordinator.presentNextIfNeeded()
        }) { draft in
            ImportReviewView(
                draft: draft,
                onSave: { reviewed in
                    _ = appModel.importCoordinator.commit(reviewed, into: store)
                },
                onCancel: {
                    appModel.importCoordinator.discardCurrentDraft()
                }
            )
        }
        .overlay {
            if let progress = coordinator.progress {
                ImportProgressOverlay(progress: progress)
            }
        }
        .alert(
            "导入提示",
            isPresented: Binding(
                get: { appModel.importCoordinator.errorMessage != nil },
                set: { newValue in
                    if !newValue { appModel.importCoordinator.errorMessage = nil }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
    }

    // MARK: iPhone

    @ViewBuilder
    private func compactLayout(_ appModel: AppModel) -> some View {
        @Bindable var model = appModel
        TabView(selection: $model.selectedTab) {
            NavigationStack(path: $model.libraryPath) {
                LibraryView(usesSelection: false)
                    .navigationDestination(for: UUID.self) { id in
                        ScoreReaderView(scoreID: id)
                    }
            }
            .tabItem { Label("曲库", systemImage: "music.note.list") }
            .tag(AppTab.library)

            NavigationStack {
                CommunityView()
            }
            .tabItem { Label("社区", systemImage: "person.3") }
            .tag(AppTab.community)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
    }

    // MARK: iPad

    @ViewBuilder
    private func regularLayout(_ appModel: AppModel) -> some View {
        @Bindable var model = appModel
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.sidebarSelection) { item in
                Label(item.title, systemImage: item.systemImage)
            }
            .navigationTitle("吉他谱")
        } content: {
            switch appModel.sidebarSelection {
            case .community:
                CommunityView()
            case .settings:
                SettingsView()
            default:
                LibraryView(usesSelection: true)
            }
        } detail: {
            NavigationStack {
                if let id = appModel.selectedScoreID {
                    ScoreReaderView(scoreID: id)
                        .id(id)
                } else {
                    ContentUnavailableView(
                        "选择一首曲谱",
                        systemImage: "guitars",
                        description: Text("从曲库中选择曲谱开始阅读，或导入新的谱子。")
                    )
                }
            }
        }
    }
}

/// Dimmed overlay with a progress indicator while an import is running.
struct ImportProgressOverlay: View {
    let progress: ImportCoordinator.ImportProgress

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 180)
                } else {
                    ProgressView()
                }
                Text(progress.message)
                    .font(.subheadline)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
