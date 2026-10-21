import Foundation
import AVFoundation

/// Owns the process-wide `AVAudioSession`: category per role, microphone permission, interruption and route-change
/// notifications (translated into plain `Event`s for the reader).
@MainActor
final class AudioSessionManager {
    enum Role: Equatable {
        /// Simulated playback: `.playback` (keeps playing in the background / with the silent switch on).
        case playback
        /// Microphone following: `.playAndRecord` + `.measurement` (no voice processing / AGC / echo cancellation,
        /// which would suppress the guitar as "noise").
        case follow
    }

    enum MicPermission: Equatable {
        case undetermined, denied, granted
    }

    enum Event: Equatable {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        /// Headphones / the previous output or input went away.
        case routeDeviceRemoved
        /// A new device (headphones, USB audio interface, Bluetooth) appeared.
        case routeDeviceAdded
        case mediaServicesReset
    }

    private(set) var activeRole: Role?
    var onEvent: ((Event) -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {}

    /// Removes the notification observers (re-installed by the next `activate`). Called when a session ends, so the
    /// observers only exist while audio is active (there is no `deinit` hop to the main actor).
    func invalidate() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
    }

    // MARK: Permission

    var micPermission: MicPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    /// Asks for microphone access when still undetermined. Returns whether recording is allowed.
    func requestMicPermission() async -> Bool {
        switch micPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    // MARK: Activation

    func activate(_ role: Role) throws {
        let session = AVAudioSession.sharedInstance()
        switch role {
        case .playback:
            try session.setCategory(.playback, mode: .default, options: [])
        case .follow:
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP])
        }
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        activeRole = role
        installObserversIfNeeded()
    }

    /// Stop all engines first, otherwise the session reports "busy" and stays active.
    func deactivate() {
        guard activeRole != nil else { return }
        activeRole = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Hardware sample rate of the current route (after activation).
    var hardwareSampleRate: Double {
        AVAudioSession.sharedInstance().sampleRate
    }

    // MARK: Notifications

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.handleInterruption(type: type, options: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reason: reason) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onEvent?(.mediaServicesReset) }
        })
    }

    private func handleInterruption(type: UInt?, options: UInt) {
        guard let type = type, let kind = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch kind {
        case .began:
            onEvent?(.interruptionBegan)
        case .ended:
            let resume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            onEvent?(.interruptionEnded(shouldResume: resume))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason: UInt?) {
        guard let reason = reason, let kind = AVAudioSession.RouteChangeReason(rawValue: reason) else { return }
        switch kind {
        case .oldDeviceUnavailable:
            onEvent?(.routeDeviceRemoved)
        case .newDeviceAvailable:
            onEvent?(.routeDeviceAdded)
        default:
            break   // category changes (our own), overrides, wake from sleep ...: ignored
        }
    }
}
