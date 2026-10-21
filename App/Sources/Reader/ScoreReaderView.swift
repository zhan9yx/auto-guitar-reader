import SwiftUI
import UIKit
import AGRCore

/// The main reading screen. Hosts the text / image document in a `ScoreScrollContainer`; the ▶︎ 播放 and 🎤 跟随
/// toolbar buttons open the playback / follow bars (driven by `ReaderConductor`).
@MainActor
struct ScoreReaderView: View {
    let scoreID: UUID

    @Environment(ScoreStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    @State private var session: ReaderSession
    @State private var conductor: ReaderConductor
    @State private var score: Score?
    @State private var pageImages: [UIImage?] = []
    @State private var loadError: String?
    @State private var fontSize: CGFloat = 18
    @State private var transpose: Int = 0
    @State private var displayMode: ScoreDisplayMode = .text
    @State private var didApplyDefaults = false
    @State private var showEditor = false

    init(scoreID: UUID, session: ReaderSession? = nil) {
        self.scoreID = scoreID
        let readerSession = session ?? ReaderSession()
        _session = State(initialValue: readerSession)
        _conductor = State(initialValue: ReaderConductor(session: readerSession))
    }

    var body: some View {
        Group {
            if let score = score {
                readerBody(score)
            } else if let loadError = loadError {
                ContentUnavailableView(
                    "无法打开曲谱",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle(score?.meta.title ?? "曲谱")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    conductor.togglePanel(.playback)
                } label: {
                    Label("播放", systemImage: conductor.panel == .playback ? "play.circle.fill" : "play.fill")
                }
                .disabled(score == nil)

                Button {
                    conductor.togglePanel(.follow)
                } label: {
                    Label("跟随", systemImage: conductor.panel == .follow ? "mic.circle.fill" : "mic.fill")
                }
                .disabled(score == nil)

                Menu {
                    Button {
                        showEditor = true
                    } label: {
                        Label("编辑谱面", systemImage: "square.and.pencil")
                    }
                    .disabled(score == nil)

                    if let summary = store.summary(for: scoreID) {
                        ShareLink(
                            item: AGRFileShare(rootURL: store.rootURL, scoreID: scoreID, title: summary.displayTitle),
                            preview: SharePreview(summary.displayTitle)
                        ) {
                            Label("分享为 .agr", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }

            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    fontSize = max(12, fontSize - 2)
                } label: {
                    Text("A−").font(.system(size: 15, weight: .semibold))
                }
                .disabled(isImageMode || fontSize <= 12)

                Button {
                    fontSize = min(40, fontSize + 2)
                } label: {
                    Text("A+").font(.system(size: 19, weight: .semibold))
                }
                .disabled(isImageMode || fontSize >= 40)

                Spacer()

                Button {
                    transpose = max(-6, transpose - 1)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .disabled(isImageMode || transpose <= -6)

                Text(transposeLabel)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(isImageMode ? Color.secondary : Color.primary)

                Button {
                    transpose = min(6, transpose + 1)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .disabled(isImageMode || transpose >= 6)

                Spacer()

                Button {
                    displayMode = (displayMode == .text) ? .image : .text
                } label: {
                    Label(
                        displayMode.label,
                        systemImage: displayMode == .text ? "text.alignleft" : "photo"
                    )
                }
                .disabled(!hasPages)
            }
        }
        .sheet(isPresented: $showEditor) {
            if let score = score {
                NavigationStack {
                    ScoreTextEditorView(score: score) { updated in
                        saveEdited(updated)
                    }
                }
            }
        }
        .onChange(of: session.isSessionActive) { _, active in
            UIApplication.shared.isIdleTimerDisabled = active
        }
        .onChange(of: effectiveTranspose) { _, value in
            conductor.setTranspose(value)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: conductor.appDidEnterBackground()
            case .active: conductor.appDidBecomeActive()
            default: break
            }
        }
        .onDisappear {
            conductor.stopAll()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .task(id: scoreID) {
            conductor.stopAll()
            loadScore()
        }
    }

    // MARK: Derived state

    private var hasPages: Bool { !(score?.pages.isEmpty ?? true) }

    private var isImageMode: Bool { displayMode == .image && hasPages }

    /// Image mode shows the picture as written, so playback / following use the original key there.
    private var effectiveTranspose: Int { isImageMode ? 0 : transpose }

    private var transposeLabel: String {
        TransposeHelper.keyLabel(original: score?.meta.key, semitones: transpose)
    }

    // MARK: Content

    @ViewBuilder
    private func readerBody(_ score: Score) -> some View {
        VStack(spacing: 0) {
            ScoreScrollContainer(driver: session.driver) {
                documentContent(score)
            }
            .background(Color(uiColor: .systemBackground))

            performancePanel
        }
    }

    @ViewBuilder
    private var performancePanel: some View {
        switch conductor.panel {
        case .none:
            EmptyView()
        case .playback:
            PlaybackBarView(
                playback: conductor.playback,
                transpose: $transpose,
                transposeLabel: transposeLabel,
                transposeEnabled: !isImageMode,
                statusMessage: conductor.statusMessage,
                onPlayPause: { conductor.togglePlayPause() },
                onRestart: { conductor.restartPlayback() },
                onClose: { conductor.closePanel() }
            )
        case .follow:
            FollowBarView(conductor: conductor, onClose: { conductor.closePanel() })
        }
    }

    @ViewBuilder
    private func documentContent(_ score: Score) -> some View {
        if displayMode == .image && !score.pages.isEmpty {
            PageImageDocumentView(
                score: score,
                images: pageImages,
                highlightedEvent: session.highlight,
                onLineFrames: { frames in handleLineFrames(frames) },
                onContentSizeChange: { size in handleContentSize(size) }
            )
        } else {
            ScoreDocumentView(
                score: score,
                fontSize: fontSize,
                transpose: transpose,
                highlightedEvent: session.highlight,
                onLineFrames: { frames in handleLineFrames(frames) },
                onContentSizeChange: { size in handleContentSize(size) }
            )
        }
    }

    private func handleLineFrames(_ frames: [LineRef: CGRect]) {
        session.driver.lineFrames = frames
    }

    private func handleContentSize(_ size: CGSize) {
        session.driver.requestRelayout()
    }

    // MARK: Loading / saving

    private func loadScore() {
        do {
            let loaded = try store.loadScore(id: scoreID)
            var images: [UIImage?] = []
            for page in loaded.pages {
                images.append(store.loadPageImage(scoreID: scoreID, name: page.fileName))
            }
            pageImages = images
            score = loaded
            loadError = nil
            conductor.bind(score: loaded, settings: settings)
            conductor.setTranspose(effectiveTranspose)
            if !didApplyDefaults {
                fontSize = CGFloat(settings.defaultFontSize)
                displayMode = (settings.defaultDisplayMode == .image && !loaded.pages.isEmpty) ? .image : .text
                didApplyDefaults = true
            }
        } catch {
            loadError = describeError(error)
        }
    }

    private func saveEdited(_ updated: Score) {
        do {
            try store.save(score: updated)
            loadScore()
        } catch {
            loadError = describeError(error)
        }
    }
}
