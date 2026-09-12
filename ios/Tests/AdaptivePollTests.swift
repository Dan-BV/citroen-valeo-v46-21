import XCTest

/// The adaptive-poll backoff curve and its caps.
final class AdaptivePollTests: XCTestCase {

    /// A page that just changed (staleness 0) is read every cycle.
    func testFreshPageIsReadEveryCycle() {
        XCTAssertEqual(AdaptivePoll.multiplier(staleness: 0), 1)
        XCTAssertEqual(AdaptivePoll.multiplier(staleness: 2), 1)
        XCTAssertEqual(AdaptivePoll.period(base: 1, staleness: 0), 1)
    }

    /// The longer it holds still, the more it is stretched - in coarse steps.
    func testBackoffGrowsInSteps() {
        XCTAssertEqual(AdaptivePoll.multiplier(staleness: 3), 2)
        XCTAssertEqual(AdaptivePoll.multiplier(staleness: 6), 2)
        XCTAssertEqual(AdaptivePoll.multiplier(staleness: 7), 4)
        XCTAssertEqual(AdaptivePoll.multiplier(staleness: 14), 4)
        XCTAssertEqual(AdaptivePoll.multiplier(staleness: 15), 8)
        XCTAssertEqual(AdaptivePoll.multiplier(staleness: 1000), 8)
    }

    /// The base period is multiplied by the backoff.
    func testPeriodMultipliesTheBase() {
        XCTAssertEqual(AdaptivePoll.period(base: 1, staleness: 15), 8)
        XCTAssertEqual(AdaptivePoll.period(base: 2, staleness: 3), 4)   // 2 x 2
        XCTAssertEqual(AdaptivePoll.period(base: 3, staleness: 0), 3)   // 3 x 1
    }

    /// Even a page that never changes is re-read within the cap, never dropped.
    func testEffectivePeriodIsCapped() {
        XCTAssertEqual(AdaptivePoll.period(base: 10, staleness: 1000), AdaptivePoll.maxPeriod)
        XCTAssertLessThanOrEqual(AdaptivePoll.period(base: 3, staleness: 1000), AdaptivePoll.maxPeriod)
    }

    /// A zero or negative base is treated as every cycle, never as "never".
    func testBaseIsAtLeastOne() {
        XCTAssertEqual(AdaptivePoll.period(base: 0, staleness: 0), 1)
    }
}
