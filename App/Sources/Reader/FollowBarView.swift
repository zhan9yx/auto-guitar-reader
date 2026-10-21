import SwiftUI
import UIKit
import AGRCore

/// Bottom bar of microphone following: start / stop, mode, confidence light, live tempo, lyrics status, input level.
@MainActor
struct FollowBarView: View {
    @Bindable var conductor: ReaderConductor
    let onClose: () -> Void

    private var follow: FollowController { conductor.follow }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if follow.phase == .micDenied {
                permissionBanner
            }
            if case .failed(let message) = follow.phase {
                Text("无法开始跟随：\(message)")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let message = conductor.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                startStopButton
                Picker("模式", selection: modeBinding) {
                    Text("弹唱").tag(FollowMode.strumSing)
                    Text("指弹").tag(FollowMode.fingerstyle)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 150)
                Spacer(minLength: 0)
                if follow.isRunning {
                    confidenceLight
                    Text(String(format: "速度 ×%.2f", follow.tempoRatio))
                        .font(.footnote.monospacedDigit())
                }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("关闭跟随栏")
            }

            if follow.isRunning {
                HStack(spacing: 10) {
                    levelMeter
                        .frame(width: 70, height: 8)
                    if follow.mode == .strumSing {
                        Text(follow.lyricsStatus.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if follow.lyricsStatus == .denied {
                            Button("打开设置") { FollowBarView.openSystemSettings() }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                        }
                    }
                    Spacer(minLength: 0)
                    if conductor.isManuallyScrolled {
                        Button {
                            conductor.resumeAutoScroll()
                        } label: {
                            Label("回到跟随", systemImage: "arrow.uturn.down")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Text("双击某行可以从该行开始跟随")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Pieces

    private var modeBinding: Binding<FollowMode> {
        Binding(get: { conductor.follow.mode }, set: { conductor.setFollowMode($0) })
    }

    private var startStopButton: some View {
        Button {
            conductor.toggleFollow()
        } label: {
            HStack(spacing: 6) {
                if follow.phase == .starting {
                    ProgressView()
                } else {
                    Image(systemName: follow.isActive ? "stop.fill" : "mic.fill")
                }
                Text(follow.isActive ? "停止跟随" : "开始跟随")
            }
            .font(.headline)
            .frame(minWidth: 110)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(follow.isActive ? Color.red : Color.accentColor)
        .accessibilityLabel(follow.isActive ? "停止跟随" : "开始跟随")
    }

    private var confidenceLight: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(lightColor)
                .frame(width: 14, height: 14)
            if follow.isPaused {
                Text("暂停")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("跟随置信度")
    }

    private var lightColor: Color {
        switch follow.confidenceLevel {
        case .none: return .gray
        case .low: return .red
        case .medium: return .yellow
        case .high: return .green
        }
    }

    private var levelMeter: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(follow.inputLevel > 0.9 ? Color.red : Color.green)
                    .frame(width: max(2, proxy.size.width * follow.inputLevel))
            }
        }
        .accessibilityLabel("输入电平")
    }

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(.red)
            Text("没有麦克风权限，无法跟随。")
                .font(.footnote)
            Spacer(minLength: 0)
            Button("打开设置") { FollowBarView.openSystemSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private static func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
