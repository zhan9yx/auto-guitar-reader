import Foundation
import AGRCore

/// User-facing follow sensitivity preset (设置 → 跟随). It scales two safe knobs of `FollowerConfig` relative to the
/// *current defaults* (so re-tuning the defaults in Core keeps the presets meaningful):
///
/// * `kappa` - sharpness of the chroma observation `exp(kappa * cos)`. Larger = the model trusts the audio more and
///   reacts faster to chord changes, but is also more easily fooled by singing / noise.
/// * `pJump` - total probability mass of "jump to another section start" at an event end. Larger = recovers faster
///   when the player skips or repeats a section, but wanders off more easily in repetitive progressions.
enum FollowSensitivity: String, CaseIterable, Identifiable {
    case steady
    case standard
    case responsive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .steady: return "稳健"
        case .standard: return "标准"
        case .responsive: return "灵敏"
        }
    }

    var detail: String {
        switch self {
        case .steady: return "抗干扰更强，不易乱跳；换和弦反应稍慢"
        case .standard: return "推荐"
        case .responsive: return "反应更快，更容易跟上跳段；嘈杂环境可能误判"
        }
    }

    /// (kappa factor, pJump factor)
    var factors: (kappa: Double, jump: Double) {
        switch self {
        case .steady: return (0.8, 0.33)
        case .standard: return (1.0, 1.0)
        case .responsive: return (1.25, 1.7)
        }
    }

    func apply(to config: inout FollowerConfig) {
        let f = factors
        config.kappa *= f.kappa
        config.pJump *= f.jump
    }

    func config(base: FollowerConfig = FollowerConfig()) -> FollowerConfig {
        var c = base
        apply(to: &c)
        return c
    }
}
