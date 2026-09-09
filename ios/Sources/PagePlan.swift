import Foundation

/// How often each page is read, and what each one costs.
///
/// Cycle time is a property of pages, not of parameters: a page costs one
/// adapter turnaround and the parameters inside it cost nothing. So the two
/// levers are which pages are in the cycle and how often each is asked for -
/// and the second one only makes sense if the cost of each page is known, which
/// is why the measured round trips are kept here and survive a restart. That
/// way the effect of a change can be shown before the car is even started,
/// rather than discovered on the road.
///
/// The defaults are the ones the Android app arrived at (`BaseSet.PERIODS`):
/// $C4 every second cycle, $CB every third, and the pages the profile marks
/// static every tenth.
final class PagePlan {

    static let choices = [1, 2, 3, 5, 10]

    private let defaults: UserDefaults
    private let periodsKey = "pagePeriods"
    private let costsKey = "pageCosts"

    private var periods: [String: Int]
    private var costs: [String: Double]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        periods = defaults.dictionary(forKey: periodsKey) as? [String: Int] ?? [:]
        costs = defaults.dictionary(forKey: costsKey) as? [String: Double] ?? [:]
    }

    // MARK: - how often

    /// Built-in defaults, before the reader has an opinion.
    static func defaultPeriod(_ page: Profile.Page) -> Int {
        if page.slow == true { return 10 }
        switch page.id {
        case "C4": return 2
        case "CB": return 3
        default: return 1
        }
    }

    func period(of page: Profile.Page) -> Int {
        periods[page.request] ?? Self.defaultPeriod(page)
    }

    func setPeriod(_ period: Int, for page: Profile.Page) {
        periods[page.request] = period
        defaults.set(periods, forKey: periodsKey)
    }

    func isCustom(_ page: Profile.Page) -> Bool {
        periods[page.request] != nil && periods[page.request] != Self.defaultPeriod(page)
    }

    func resetPeriods() {
        periods = [:]
        defaults.removeObject(forKey: periodsKey)
    }

    // MARK: - what it costs

    /// A round trip, folded into a running estimate. An exponential average
    /// rather than a median so nothing has to be kept: a page's cost drifts
    /// with the adapter and the ECU's mood, and the last few reads are what
    /// matter.
    func record(_ ms: Int, for page: Profile.Page) {
        let previous = costs[page.request]
        costs[page.request] = previous.map { $0 * 0.7 + Double(ms) * 0.3 } ?? Double(ms)
        defaults.set(costs, forKey: costsKey)
    }

    func cost(of page: Profile.Page) -> Int? {
        costs[page.request].map { Int($0.rounded()) }
    }

    func forgetCosts() {
        costs = [:]
        defaults.removeObject(forKey: costsKey)
    }

    // MARK: - what a cycle will take

    /// Average cycle time over a long run: a page read every `period` cycles
    /// contributes its cost divided by that period.
    ///
    /// `nil` while no page in the cycle has ever been measured - a guess from
    /// the byte layout would be worse than saying nothing, since the whole
    /// point of the number is that it comes from this adapter.
    func predictedCycleMs(_ pages: [Profile.Page]) -> Int? {
        var total = 0.0
        var measured = 0
        for page in pages {
            guard let cost = costs[page.request] else { continue }
            total += cost / Double(period(of: page))
            measured += 1
        }
        guard measured > 0 else { return nil }
        return Int(total.rounded())
    }

    /// How much of the cycle each page is responsible for, biggest first, for a
    /// screen that wants to show where the time goes.
    func breakdown(_ pages: [Profile.Page]) -> [(page: Profile.Page, share: Int)] {
        pages
            .compactMap { page -> (page: Profile.Page, share: Int)? in
                guard let cost = costs[page.request] else { return nil }
                return (page, Int((cost / Double(period(of: page))).rounded()))
            }
            .sorted { $0.share > $1.share }
    }
}
