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

    /// Which CAN request headers this adapter can address at all.
    ///
    /// Empty means "any", which is what an ELM327 is: it sends whatever header
    /// `ATSH` was given. A ThinkDiag cannot - no CAN identifier crosses its
    /// wire, so it only reaches the modules whose handles are in its table -
    /// and the whole-car fault sweep needs to say so rather than report every
    /// module on the car as silent.
    var addressableHeaders: Set<String> { get }

    /// The module handles this adapter addresses modules by, when it does not
    /// use CAN identifiers at all.
    ///
    /// Empty for an ELM327, which has no such notion. A ThinkDiag's whole
    /// vocabulary is these, and which of them is which module is not written
    /// anywhere - so the fault sweep has a second shape for this adapter:
    /// walk the handles, and let the recognition frames say what answered.
    var knownLinks: [UInt16] { get }

    /// How bringing the link up went, in lines meant for a person to read.
    ///
    /// Nothing for an ELM327 clone: its opening is fourteen AT commands that
    /// either work or leave the chip unreachable, and its one interesting
    /// answer already shows as `ElmProbe`'s verdict. A ThinkDiag's opening is
    /// eight exchanges of a protocol that was reverse-engineered, two of them
    /// still open questions - and when it fails the only thing worth knowing
    /// is *which step* it stopped answering at.
    var openingReport: [String] { get }
}

extension Adapter {
    /// Nothing to say unless a conformer has something to say.
    var openingReport: [String] { [] }

    /// No restriction unless a conformer has one.
    var addressableHeaders: Set<String> { [] }

    /// CAN identifiers, unless a conformer says otherwise.
    var knownLinks: [UInt16] { [] }
}
