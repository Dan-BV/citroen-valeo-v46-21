import XCTest

/// Cycle time is a property of pages, so the arithmetic that predicts it has to
/// be right: it is what the reader trades against on screen, before driving.
final class PlanTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var profile: Profile!

    override func setUpWithError() throws {
        suite = "PagePlanTests-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        profile = try Profile.bundled(in: Bundle(for: PlanTests.self))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func page(_ id: String) throws -> Profile.Page {
        try XCTUnwrap(profile.pages.first { $0.id == id })
    }

    // MARK: - how often

    /// The defaults are the ones the Android app arrived at, and the two static
    /// pages come from the profile rather than from a list here.
    func testDefaultRatesMatchTheAndroidOnes() throws {
        let plan = PagePlan(defaults: defaults)
        XCTAssertEqual(plan.period(of: try page("C0")), 1, "mixture, every cycle")
        XCTAssertEqual(plan.period(of: try page("C4")), 2, "torque, every second")
        XCTAssertEqual(plan.period(of: try page("CB")), 3, "environment, every third")
        XCTAssertEqual(plan.period(of: try page("B0")), 10, "immobilizer holds still")
        XCTAssertEqual(plan.period(of: try page("CF")), 10, "the service record too")
    }

    func testAChosenRateSurvivesARestart() throws {
        let page = try page("C0")
        PagePlan(defaults: defaults).setPeriod(5, for: page)

        let reopened = PagePlan(defaults: defaults)
        XCTAssertEqual(reopened.period(of: page), 5)
        XCTAssertTrue(reopened.isCustom(page))

        reopened.resetPeriods()
        XCTAssertEqual(PagePlan(defaults: defaults).period(of: page), 1)
    }

    /// The picker offers a page only its default rate and slower ones - the
    /// default is the minimum, the coarsest choice the maximum.
    func testChoicesForAPageStartAtItsDefault() throws {
        XCTAssertEqual(PagePlan.choices(for: try page("C0")).first, 1)   // every cycle
        XCTAssertEqual(PagePlan.choices(for: try page("C4")).first, 2)   // not faster than its default
        XCTAssertEqual(PagePlan.choices(for: try page("CB")).first, 3)
        XCTAssertEqual(PagePlan.choices(for: try page("B0")).first, 10)  // a static page starts rare
        XCTAssertEqual(PagePlan.choices(for: try page("C0")).last, PagePlan.choices.last)
        XCTAssertFalse(PagePlan.choices(for: try page("CB")).contains(1), "no faster than the default")
    }

    /// A rate below the page's default - a legacy value, or a bad write - is
    /// clamped up to the default rather than polling a heavy page too fast.
    func testARateBelowTheDefaultIsClampedUp() throws {
        let plan = PagePlan(defaults: defaults)
        let page = try page("CB")                 // default 3
        plan.setPeriod(1, for: page)
        XCTAssertEqual(plan.period(of: page), 3, "clamped up to the default floor")
        plan.setPeriod(10, for: page)
        XCTAssertEqual(plan.period(of: page), 10, "above the floor is kept")
    }

    // MARK: - what it costs

    func testTheFirstMeasurementIsTakenAsIsAndLaterOnesAveraged() throws {
        let plan = PagePlan(defaults: defaults)
        let page = try page("C0")
        XCTAssertNil(plan.cost(of: page), "nothing measured yet")

        plan.record(240, for: page)
        XCTAssertEqual(plan.cost(of: page), 240)

        // 0.7 * 240 + 0.3 * 140 = 210
        plan.record(140, for: page)
        XCTAssertEqual(plan.cost(of: page), 210)
    }

    func testCostsSurviveARestartSoAnEstimateExistsBeforeConnecting() throws {
        let page = try page("C0")
        PagePlan(defaults: defaults).record(240, for: page)
        XCTAssertEqual(PagePlan(defaults: defaults).cost(of: page), 240)
    }

    // MARK: - the estimate

    func testACycleIsTheSumOfEachPagesCostOverItsRate() throws {
        let plan = PagePlan(defaults: defaults)
        let fast = try page("C0")     // every cycle
        let slower = try page("C4")   // every second
        let rare = try page("CB")     // every third

        plan.record(240, for: fast)
        plan.record(60, for: slower)
        plan.record(210, for: rare)

        // 240/1 + 60/2 + 210/3 = 240 + 30 + 70
        XCTAssertEqual(plan.predictedCycleMs([fast, slower, rare]), 340)
    }

    func testHalvingTheRateOfTheHeaviestPageHalvesItsShare() throws {
        let plan = PagePlan(defaults: defaults)
        let heavy = try page("C0")
        plan.record(240, for: heavy)
        XCTAssertEqual(plan.predictedCycleMs([heavy]), 240)

        plan.setPeriod(2, for: heavy)
        XCTAssertEqual(plan.predictedCycleMs([heavy]), 120)
        plan.setPeriod(10, for: heavy)
        XCTAssertEqual(plan.predictedCycleMs([heavy]), 24)
    }

    /// A guess from the byte layout would be worse than silence: the whole
    /// point of the number is that it came from this adapter.
    func testNoEstimateBeforeAnythingWasMeasured() throws {
        let plan = PagePlan(defaults: defaults)
        XCTAssertNil(plan.predictedCycleMs(profile.pages))
    }

    func testAnUnmeasuredPageIsLeftOutRatherThanGuessed() throws {
        let plan = PagePlan(defaults: defaults)
        let measured = try page("C0")
        plan.record(240, for: measured)
        XCTAssertEqual(plan.predictedCycleMs([measured, try page("C1")]), 240)
    }

    func testTheBreakdownPutsTheExpensivePageFirst() throws {
        let plan = PagePlan(defaults: defaults)
        let heavy = try page("C0")
        let light = try page("C4")
        plan.record(240, for: heavy)
        plan.record(60, for: light)

        let breakdown = plan.breakdown([light, heavy])
        XCTAssertEqual(breakdown.first?.page.id, "C0")
        XCTAssertEqual(breakdown.first?.share, 240)
        XCTAssertEqual(breakdown.last?.share, 30, "60 ms every second cycle")
    }
}
