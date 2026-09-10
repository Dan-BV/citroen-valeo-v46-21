import Foundation

/// What a session needs from whatever is on the other end of the link.
///
/// `ElmSession` talks to nothing else: eight members, and the ELM327 command
/// vocabulary passing through `send`. That is the whole seam, and it is why a
/// second kind of adapter costs no change in the session at all.
///
/// The second kind is coming. A ThinkDiag speaks Launch's own `55aa` framing
/// rather than ELM327 text, so it will implement this by interpreting the
/// commands instead of forwarding them - see `out/thinkdiag_transport_plan.md`.
///
/// Actor-constrained because an exchange is one command at a time. Staying
/// indivisible across several exchanges is a different problem, and `AsyncLock`
/// in the session is what solves it.
protocol Adapter: Actor {

    /// Bring the link up. Throws if it cannot be brought up at all.
    func open() async throws

    /// Tear the link down. Callable from anywhere, including a teardown path
    /// that is not already on the actor.
    nonisolated func close()

    /// How long since the last command went out, for the keep-alive.
    func idleFor() -> TimeInterval

    /// Point the adapter at one ECU. Cheap to call repeatedly: a conformer is
    /// expected to remember the current header and do nothing when it has not
    /// changed, because switching costs two exchanges.
    func applyHeader(_ header: String, receive: String) async

    /// Send one command and return the reply, or an empty string if none came
    /// before `timeout`. An empty reply means the ECU did not answer; a link
    /// that has died is reported through `linkFailure` instead, and the two
    /// must not be confused - one is a page to try again, the other a session
    /// to end.
    @discardableResult
    func send(_ command: String, _ timeout: TimeInterval) async -> String

    /// What the last exchange cost. Feeds the technical log, which is how a
    /// change in adapter gets judged rather than assumed.
    var lastStats: LinkStats { get }
    var lastMs: Int { get }

    /// Set once the link itself has failed.
    var linkFailure: TransportError? { get }
}
