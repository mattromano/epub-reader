import Foundation
import Testing
@testable import Tracking

@Suite struct TrackerConfigTests {
    @Test func specDefaults() {
        let config = TrackerConfig(timeZone: TimeZone(identifier: "UTC")!)
        #expect(config.idleThreshold == 180)
        #expect(config.sessionGap == 300)
        #expect(config.dayStartHour == 4)
    }
}
