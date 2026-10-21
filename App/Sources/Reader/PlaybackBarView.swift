import SwiftUI
import AGRCore

/// Bottom bar of simulated playback. Inline (two rows) on iPad / regular width, compact on iPhone (the less common
/// controls fold into "更多").
@MainActor
struct PlaybackBarView: View {
    @Bindable var playback: PlaybackController
    @Binding var transpose: Int
    let transposeLabel: String
    let transposeEnabled: Bool
    let statusMessage: String?
    let onPlayPause: () -> Void
    let onRestart: () -> Void
    let onClose: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showMore = false

    var body: some View {
        VStack(spacing: 8) {
            if let message = statusMessage ?? playback.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if sizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Layouts

    private var regularLayout: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                transportButtons
                tempoControl
                transposeControl
                strumMenu
                toggles
                closeButton
            }
            HStack(spacing: 16) {
                loopMenu
                labeledSlider("音量", value: $playback.volume)
                labeledSlider("音色", value: $playback.brightness)
            }
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                transportButtons
                tempoControl
                closeButton
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    transposeControl
                    strumMenu
                    toggles
                }
            }
            DisclosureGroup("更多", isExpanded: $showMore) {
                VStack(spacing: 8) {
                    HStack { loopMenu; Spacer() }
                    labeledSlider("音量", value: $playback.volume)
                    labeledSlider("音色", value: $playback.brightness)
                }
                .padding(.top, 4)
            }
            .font(.footnote)
        }
    }

    // MARK: Pieces

    private var transportButtons: some View {
        HStack(spacing: 14) {
            Button(action: onPlayPause) {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
            }
            .accessibilityLabel(playback.isPlaying ? "暂停" : "播放")
            Button(action: onRestart) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 20))
            }
            .accessibilityLabel("从头播放")
        }
    }

    private var tempoControl: some View {
        HStack(spacing: 8) {
            Text(playback.bpmLabel)
                .font(.footnote.monospacedDigit())
                .frame(minWidth: 62, alignment: .trailing)
            Slider(value: $playback.tempoScale, in: PlaybackParameters.tempoRange, step: 0.05)
                .frame(minWidth: 90)
            Text(playback.tempoPercentLabel)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .leading)
        }
    }

    private var transposeControl: some View {
        HStack(spacing: 6) {
            Button {
                transpose = max(-6, transpose - 1)
            } label: {
                Image(systemName: "minus.circle")
            }
            .disabled(!transposeEnabled || transpose <= -6)
            Text(transposeLabel)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(transposeEnabled ? Color.primary : Color.secondary)
                .frame(minWidth: 56)
            Button {
                transpose = min(6, transpose + 1)
            } label: {
                Image(systemName: "plus.circle")
            }
            .disabled(!transposeEnabled || transpose >= 6)
        }
    }

    private var strumMenu: some View {
        Picker("节奏型", selection: $playback.strumID) {
            Text("跟随谱面").tag(String?.none)
            ForEach(playback.strumOptions) { pattern in
                Text(pattern.name).tag(String?.some(pattern.id))
            }
        }
        .pickerStyle(.menu)
        .font(.footnote)
    }

    private var toggles: some View {
        HStack(spacing: 8) {
            Toggle("预备拍", isOn: $playback.countInEnabled)
            Toggle("节拍器", isOn: $playback.metronome)
        }
        .toggleStyle(.button)
        .font(.footnote)
    }

    private var loopMenu: some View {
        Picker("循环段落", selection: $playback.loopPass) {
            Text("不循环").tag(Int?.none)
            ForEach(playback.loopOptions) { option in
                Text(option.title).tag(Int?.some(option.passIndex))
            }
        }
        .pickerStyle(.menu)
        .font(.footnote)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("关闭播放栏")
    }

    private func labeledSlider(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Slider(value: value, in: 0...1)
                .frame(minWidth: 80)
        }
    }
}
