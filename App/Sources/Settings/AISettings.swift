import Foundation
import Observation
import AGRCore

enum AIProviderPreset: String, CaseIterable, Identifiable {
    case deepSeek
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .deepSeek: return "DeepSeek"
        case .custom: return "自定义（OpenAI 兼容）"
        }
    }

    /// Values filled in when the preset is chosen (nil = leave the fields alone).
    var baseURL: String? { self == .deepSeek ? AIProviderConfig.deepSeekBaseURL.absoluteString : nil }
    var model: String? { self == .deepSeek ? AIProviderConfig.deepSeekModel : nil }
}

/// Settings of the optional AI-assisted recognition. Everything except the API key lives in
/// `UserDefaults`; the key lives only in the `SecretStore` (Keychain).
@Observable
@MainActor
final class AISettings {
    enum Keys {
        static let enabled = "settings.ai.enabled"
        static let preset = "settings.ai.preset"
        static let baseURL = "settings.ai.baseURL"
        static let model = "settings.ai.model"
        static let vision = "settings.ai.supportsVision"
        static let confirm = "settings.ai.confirmBeforeSend"
    }

    static let keychainAccount = "api-key"

    private let defaults: UserDefaults
    private let secrets: SecretStore

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }
    var preset: AIProviderPreset {
        didSet { defaults.set(preset.rawValue, forKey: Keys.preset) }
    }
    var baseURLString: String {
        didSet { defaults.set(baseURLString, forKey: Keys.baseURL) }
    }
    var model: String {
        didSet { defaults.set(model, forKey: Keys.model) }
    }
    /// 支持图片（视觉模型）: attach crops of the flagged regions.
    var supportsVision: Bool {
        didSet { defaults.set(supportsVision, forKey: Keys.vision) }
    }
    /// 发送前确认.
    var confirmBeforeSend: Bool {
        didSet { defaults.set(confirmBeforeSend, forKey: Keys.confirm) }
    }
    /// Held in memory, persisted to the Keychain only (never UserDefaults).
    var apiKey: String {
        didSet { secrets.set(apiKey.trimmed, for: Self.keychainAccount) }
    }

    init(defaults: UserDefaults = .standard, secrets: SecretStore = DefaultSecretStore.make()) {
        self.defaults = defaults
        self.secrets = secrets
        let preset = AIProviderPreset(rawValue: defaults.string(forKey: Keys.preset) ?? "") ?? .deepSeek
        self.preset = preset
        self.isEnabled = (defaults.object(forKey: Keys.enabled) as? Bool) ?? false
        self.baseURLString = defaults.string(forKey: Keys.baseURL) ?? preset.baseURL ?? ""
        self.model = defaults.string(forKey: Keys.model) ?? preset.model ?? ""
        self.supportsVision = (defaults.object(forKey: Keys.vision) as? Bool) ?? false
        self.confirmBeforeSend = (defaults.object(forKey: Keys.confirm) as? Bool) ?? true
        self.apiKey = secrets.string(for: Self.keychainAccount) ?? ""
    }

    /// Chooses a preset and fills base URL / model for DeepSeek (custom keeps the current values).
    func selectPreset(_ newPreset: AIProviderPreset) {
        preset = newPreset
        if let url = newPreset.baseURL { baseURLString = url }
        if let model = newPreset.model { self.model = model }
    }

    /// Connection config ignoring the enable toggle (used by 测试连接). nil when URL / model / key are unusable.
    var connectionConfig: AIProviderConfig? {
        let text = baseURLString.trimmed
        let name = model.trimmed
        let key = apiKey.trimmed
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil, !name.isEmpty, !key.isEmpty else { return nil }
        return AIProviderConfig(baseURL: url, model: name, apiKey: key, supportsVision: supportsVision)
    }

    /// Config for real assist runs: nil unless enabled and complete.
    var providerConfig: AIProviderConfig? { isEnabled ? connectionConfig : nil }

    /// Why `providerConfig` is nil (shown to the user).
    var unavailableReason: String? {
        if providerConfig != nil { return nil }
        if !isEnabled { return "未启用 AI 辅助识别（设置 → AI 辅助识别）" }
        if apiKey.trimmed.isEmpty { return "请先填写 API Key" }
        if model.trimmed.isEmpty { return "请先填写模型名" }
        return "Base URL 无效"
    }
}
