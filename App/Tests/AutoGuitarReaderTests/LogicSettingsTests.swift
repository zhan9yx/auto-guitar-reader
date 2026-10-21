import XCTest
import AGRCore
#if canImport(AutoGuitarReader)
@testable import AutoGuitarReader
#else
@testable import AppLogic
#endif

final class LogicSettingsTests: XCTestCase {
    @MainActor
    private func makeDefaults() -> UserDefaults {
        let suite = "AGRTests.logic.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testDefaultsFollowTheScoreAndSmoothScrolling() {
        MainActor.assumeIsolated {
            let s = SettingsStore(defaults: makeDefaults())
            XCTAssertNil(s.strumPatternID, "strum pattern defaults to 跟随谱面")
            XCTAssertNil(s.defaultStrumPattern)
            XCTAssertEqual(s.autoScrollStyle, .smooth)
            XCTAssertEqual(s.followSensitivity, .standard)
            XCTAssertEqual(s.autoScrollSettings.style, .smooth)
            XCTAssertEqual(s.autoScrollSettings.scroll.anchorRatio, 0.30)
            XCTAssertEqual(s.autoScrollSettings.scroll.maxSpeed, 0.6)
            XCTAssertEqual(s.followerConfig.kappa, FollowerConfig().kappa, accuracy: 1e-12)
        }
    }

    func testNewSettingsPersistAndMapToCoreConfigs() {
        MainActor.assumeIsolated {
            let defaults = makeDefaults()
            let first = SettingsStore(defaults: defaults)
            first.strumPatternID = StrumPattern.arpeggio.id
            first.autoScrollStyle = .pageTurn
            first.followSensitivity = .responsive
            first.scrollManualOverrideSeconds = 5
            first.scrollAnchorRatio = 0.4
            first.scrollMaxSpeed = 0.9

            let second = SettingsStore(defaults: defaults)
            XCTAssertEqual(second.strumPatternID, StrumPattern.arpeggio.id)
            XCTAssertEqual(second.defaultStrumPattern, StrumPattern.arpeggio)
            XCTAssertEqual(second.autoScrollStyle, .pageTurn)
            XCTAssertEqual(second.followSensitivity, .responsive)
            let a = second.autoScrollSettings
            XCTAssertEqual(a.style, .pageTurn)
            XCTAssertEqual(a.scroll.manualOverrideSeconds, 5)
            XCTAssertEqual(a.pageTurn.manualOverrideSeconds, 5)
            XCTAssertEqual(a.scroll.anchorRatio, 0.4)
            XCTAssertEqual(a.scroll.maxSpeed, 0.9)
            XCTAssertGreaterThan(second.followerConfig.kappa, FollowerConfig().kappa)

            // Back to 跟随谱面: the key is removed.
            second.strumPatternID = nil
            XCTAssertNil(SettingsStore(defaults: defaults).strumPatternID)
        }
    }
}
