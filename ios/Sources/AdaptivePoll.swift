import Foundation

/// Adaptive polling: read a page less often while its selected values hold
/// still, and snap back to every cycle the instant one moves.
///
/// The cost of a cycle is paid per page read (one adapter round trip each), so
/// the way to a faster screen is to spend those round trips on the pages whose
/// values are actually changing right now. A page's *base* period (from the
/// profile and the reader's choice) still applies; this multiplies it by a
/// backoff that grows the longer the page's selected values have not changed,
/// and collapses to 1 the moment they do.
///
/// The backoff is capped, and the effective period is capped, so even a page
/// that never changes is still re-read now and then - a slow drift is caught
/// within one capped period, never missed forever.
///
/// It changes only *when* a page is asked, never *what* is asked, so it cannot
/// affect the car; turning it off restores fixed-period polling exactly.
enum AdaptivePoll {

    /// The most a page's effective period is ever stretched to, in cycles, so a
    /// static page is still re-checked about this often.
    static let maxPeriod = 20

    /// How much to stretch a page's base period given how many consecutive
    /// reads returned the same selected values.
    ///
    /// The steps are deliberately coarse: full rate while anything might still
    /// be settling, then doubling as a page proves quiet, to a cap of ×8.
    static func multiplier(staleness: Int) -> Int {
        switch staleness {
        case ..<3: return 1
        case 3..<7: return 2
        case 7..<15: return 4
        default: return 8
        }
    }

    /// The effective period for a page: its base period stretched by the
    /// backoff, never beyond `maxPeriod`.
    static func period(base: Int, staleness: Int) -> Int {
        min(max(base, 1) * multiplier(staleness: staleness), maxPeriod)
    }
}
