import Foundation
import Observation
import AGRCore

enum RecognitionLanguage: String, CaseIterable, Identifiable {
    case zhCN = "zh-CN"
    case enUS = "en-US"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .zhCN: return "中文（普通话）"
        case .enUS: return "English"
        }
    }
}

/// App settings persisted in `UserDefaults`.
@Observable
@MainActor
final class SettingsStore {
    enum Keys {
        static let serverURL = "settings.serverURL"
        static let nickname = "settings.nickname"
        static let deviceID = "settings.deviceID"
        static let fontSize = "settings.defaultFontSize"
        static let displayMode = "settings.defaultDisplayMode"
        static let anchorRatio = "settings.scroll.anchorRatio"
        static let maxSpeed = "settings.scroll.maxSpeed"
        static let manualOverride = "settings.scroll.manualOverrideSeconds"
        static let lyricsRecognition = "settings.follow.lyricsRecognition"
        static let recognitionLanguage = "settings.follow.language"
        static let strumPattern = "settings.playback.strumPatternID"
        static let countIn = "settings.playback.countInBeats"
    }

    static let defaultServerURL = "http://localhost:8000"

    private let defaults: UserDefaults

    /// Generated once on first launch; identifies this device to the community server.
    let deviceID: String

    var serverURLString: String {
        didSet { defaults.set(serverURLString, forKey: Keys.serverURL) }
    }
    var nickname: String {
        didSet { defaults.set(nickname, forKey: Keys.nickname) }
    }
    var defaultFontSize: Double {
        didSet { defaults.set(defaultFontSize, forKey: Keys.fontSize) }
    }
    var defaultDisplayMode: ScoreDisplayMode {
        didSet { defaults.set(defaultDisplayMode.rawValue, forKey: Keys.displayMode) }
    }

    // Auto-scroll (mirrors ScrollConfig fields)
    var scrollAnchorRatio: Double {
        didSet { defaults.set(scrollAnchorRatio, forKey: Keys.anchorRatio) }
    }
    var scrollMaxSpeed: Double {
        didSet { defaults.set(scrollMaxSpeed, forKey: Keys.maxSpeed) }
    }
    var scrollManualOverrideSeconds: Double {
        didSet { defaults.set(scrollManualOverrideSeconds, forKey: Keys.manualOverride) }
    }

    // Follow
    var lyricsRecognitionEnabled: Bool {
        didSet { defaults.set(lyricsRecognitionEnabled, forKey: Keys.lyricsRecognition) }
    }
    var recognitionLanguage: RecognitionLanguage {
        didSet { defaults.set(recognitionLanguage.rawValue, forKey: Keys.recognitionLanguage) }
    }

    // Playback
    var strumPatternID: String {
        didSet { defaults.set(strumPatternID, forKey: Keys.strumPattern) }
    }
    var countInBeats: Int {
        didSet { defaults.set(countInBeats, forKey: Keys.countIn) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let device: String
        if let existing = defaults.string(forKey: Keys.deviceID), !existing.isEmpty {
            device = existing
        } else {
            device = UUID().uuidString
            defaults.set(device, forKey: Keys.deviceID)
        }
        self.deviceID = device

        self.serverURLString = defaults.string(forKey: Keys.serverURL) ?? SettingsStore.defaultServerURL
        self.nickname = defaults.string(forKey: Keys.nickname) ?? "吉他手" + String(device.prefix(4))
        self.defaultFontSize = SettingsStore.double(defaults, Keys.fontSize, 18)
        self.defaultDisplayMode = ScoreDisplayMode(rawValue: defaults.string(forKey: Keys.displayMode) ?? "") ?? .text
        self.scrollAnchorRatio = SettingsStore.double(defaults, Keys.anchorRatio, 0.30)
        self.scrollMaxSpeed = SettingsStore.double(defaults, Keys.maxSpeed, 0.6)
        self.scrollManualOverrideSeconds = SettingsStore.double(defaults, Keys.manualOverride, 3)
        self.lyricsRecognitionEnabled = SettingsStore.bool(defaults, Keys.lyricsRecognition, true)
        self.recognitionLanguage = RecognitionLanguage(rawValue: defaults.string(forKey: Keys.recognitionLanguage) ?? "") ?? .zhCN
        self.strumPatternID = defaults.string(forKey: Keys.strumPattern) ?? StrumPattern.defaultPop.id
        self.countInBeats = SettingsStore.int(defaults, Keys.countIn, 4)
    }

    private static func double(_ defaults: UserDefaults, _ key: String, _ fallback: Double) -> Double {
        (defaults.object(forKey: key) as? Double) ?? fallback
    }

    private static func bool(_ defaults: UserDefaults, _ key: String, _ fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? fallback
    }

    private static func int(_ defaults: UserDefaults, _ key: String, _ fallback: Int) -> Int {
        (defaults.object(forKey: key) as? Int) ?? fallback
    }

    // MARK: Derived

    /// Scroll configuration for the (next-phase) auto-scroller.
    var scrollConfig: ScrollConfig {
        var config = ScrollConfig()
        config.anchorRatio = scrollAnchorRatio
        config.maxSpeed = scrollMaxSpeed
        config.manualOverrideSeconds = scrollManualOverrideSeconds
        return config
    }

    var availableStrumPatterns: [StrumPattern] {
        [StrumPattern.defaultPop, StrumPattern.arpeggio]
    }

    var serverURL: URL? {
        let text = serverURLString.trimmed
        guard let url = URL(string: text), let scheme = url.scheme, scheme.hasPrefix("http"), url.host != nil else {
            return nil
        }
        return url
    }

    /// Community client for the configured server (nil when the URL is invalid).
    func communityClient(nicknameOverride: String? = nil) -> CommunityClient? {
        guard let url = serverURL else { return nil }
        let name = (nicknameOverride ?? nickname).trimmed
        return CommunityClient(baseURL: url, deviceID: deviceID, nickname: name.isEmpty ? "匿名" : name)
    }
}
