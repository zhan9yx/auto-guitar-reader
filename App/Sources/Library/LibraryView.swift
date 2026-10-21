import SwiftUI
import AGRCore

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return "最近更新"
        case .title: return "标题"
        }
    }
}

struct LibraryRow: View {
    let summary: ScoreSummary

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let artist = summary.artist, !artist.isEmpty {
                        Text(artist)
                    }
                    if let key = summary.key, !key.isEmpty {
                        Text("原调 \(key)")
                    }
                    Text(summary.updatedAt, format: .dateTime.year().month().day())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if summary.hasPages {
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ModeBadge(mode: summary.mode)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct ModeBadge: View {
    let mode: PlayMode

    var body: some View {
        Text(mode.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(mode == .strumSing ? Color.accentColor.opacity(0.15) : Color.orange.opacity(0.18))
            )
            .foregroundStyle(mode == .strumSing ? Color.accentColor : Color.orange)
    }
}

/// The score library: search, sort, swipe actions, context menu, import menu.
@MainActor
struct LibraryView: View {
    /// iPad: rows are selectable (detail column shows the reader); iPhone: rows push via NavigationLink.
    let usesSelection: Bool

    @Environment(ScoreStore.self) private var store
    @Environment(AppModel.self) private var appModel

    @State private var searchText = ""
    @State private var sort: LibrarySort = .recent
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showPaste = false
    @State private var renameTarget: ScoreSummary?
    @State private var renameText = ""
    @State private var uploadTarget: ScoreSummary?
    @State private var actionError: String?

    var body: some View {
        @Bindable var model = appModel

        Group {
            if store.summaries.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if usesSelection {
                List(selection: $model.selectedScoreID) {
                    rows
                }
            } else {
                List {
                    rows
                }
            }
        }
        .navigationTitle("曲库")
        .searchable(text: $searchText, prompt: "搜索标题或歌手")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("排序", selection: $sort) {
                        ForEach(LibrarySort.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ImportMenuItems(
                        showFiles: $showFiles,
                        showPhotos: $showPhotos,
                        showCamera: $showCamera,
                        showPaste: $showPaste
                    )
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .importSources(
            showFiles: $showFiles,
            showPhotos: $showPhotos,
            showCamera: $showCamera,
            showPaste: $showPaste
        )
        .sheet(item: $uploadTarget) { target in
            UploadSheet(summary: target)
        }
        .alert(
            "重命名",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("标题", text: $renameText)
            Button("好") {
                if let target = renameTarget, !renameText.trimmed.isEmpty {
                    do {
                        try store.rename(id: target.id, title: renameText)
                    } catch {
                        actionError = describeError(error)
                    }
                }
                renameTarget = nil
            }
            Button("取消", role: .cancel) {
                renameTarget = nil
            }
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: Data

    private var filtered: [ScoreSummary] {
        let query = searchText.trimmed
        var items = store.summaries
        if !query.isEmpty {
            items = items.filter { summary in
                summary.title.localizedCaseInsensitiveContains(query)
                    || (summary.artist ?? "").localizedCaseInsensitiveContains(query)
            }
        }
        switch sort {
        case .recent:
            items.sort { $0.updatedAt > $1.updatedAt }
        case .title:
            items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return items
    }

    // MARK: Rows

    private var rows: some View {
        ForEach(filtered) { summary in
            rowContent(summary)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        delete(summary)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .contextMenu {
                    contextMenuItems(summary)
                }
        }
    }

    @ViewBuilder
    private func rowContent(_ summary: ScoreSummary) -> some View {
        if usesSelection {
            LibraryRow(summary: summary)
                .tag(summary.id)
        } else {
            NavigationLink(value: summary.id) {
                LibraryRow(summary: summary)
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(_ summary: ScoreSummary) -> some View {
        Button {
            renameText = summary.title
            renameTarget = summary
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button {
            duplicate(summary)
        } label: {
            Label("复制", systemImage: "plus.square.on.square")
        }
        ShareLink(
            item: AGRFileShare(rootURL: store.rootURL, scoreID: summary.id, title: summary.displayTitle),
            preview: SharePreview(summary.displayTitle)
        ) {
            Label("分享为 .agr", systemImage: "square.and.arrow.up")
        }
        ShareLink(
            item: ChordProFileShare(rootURL: store.rootURL, scoreID: summary.id, title: summary.displayTitle),
            preview: SharePreview(summary.displayTitle)
        ) {
            Label("导出 ChordPro 文本", systemImage: "doc.text")
        }
        Button {
            uploadTarget = summary
        } label: {
            Label("上传到社区", systemImage: "icloud.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) {
            delete(summary)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("曲库是空的", systemImage: "music.note.list")
        } description: {
            Text("导入图片谱、PDF、ChordPro 或文本，或从社区下载曲谱。")
        } actions: {
            Menu {
                ImportMenuItems(
                    showFiles: $showFiles,
                    showPhotos: $showPhotos,
                    showCamera: $showCamera,
                    showPaste: $showPaste
                )
            } label: {
                Text("导入曲谱")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Actions

    private func delete(_ summary: ScoreSummary) {
        store.delete(id: summary.id)
        appModel.didDelete(scoreID: summary.id)
    }

    private func duplicate(_ summary: ScoreSummary) {
        do {
            try store.duplicate(id: summary.id)
        } catch {
            actionError = describeError(error)
        }
    }
}
