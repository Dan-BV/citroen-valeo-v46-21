import Foundation

/// The adapter side of a session: one command at a time, plus the CAN header
/// the adapter is currently set to.
///
/// An actor is right here - each method is a single exchange and does not need
/// to stay indivisible across several of them; that is what `AsyncLock` is for.
actor ElmAdapter: Adapter {
    private let transport: any ElmTransport
    private var header: String?
    private var lastCommand = Date.distantPast

    /// What the last exchange cost, for the technical log.
    private(set) var lastStats = LinkStats()
    private(set) var lastMs = 0

    /// Set when the link itself failed, as against the ECU declining to
    /// answer. To a caller that only sees an empty reply the two look
    /// identical, and they could not be more different: one is a page to try
    /// again, the other is a session to end.
    ///
    /// Swallowing this cost a drive on 2026-09-10. The adapter lost power with
    /// the ignition, every write threw at once, and because a failed write
    /// returned an empty string with no delay the loop went round two thousand
    /// times a second - 66 000 dead exchanges and a 4.7 MB technical log in six
    /// minutes, while the screen still read "Подключено · 0 мс".
    private(set) var linkFailure: TransportError?

    init(transport: any ElmTransport) {
        self.transport = transport
    }

    func open() async throws {
        try await transport.open()
    }

    nonisolated func close() {
        transport.close()
    }

    func idleFor() -> TimeInterval {
        Date().timeIntervalSince(lastCommand)
    }

    func applyHeader(_ header: String, receive: String) async {
        guard self.header != header else { return }
        await send("ATSH" + header, 0.6)
        await send("ATCRA" + receive, 0.6)
        self.header = header
    }

    /// Sends one ELM command (adds CR) and reads until the `>` prompt or the
    /// timeout.
    ///
    /// The drain first is not optional. Anything still buffered belongs to an
    /// earlier exchange - a reply that arrived after its timeout, or trailing
    /// bytes after the prompt. Left in place it is read as the answer to the
    /// next command, and from then on every read returns the previous page's
    /// data: the marker no longer matches, so page after page looks dead.
    @discardableResult
    func send(_ command: String, _ timeout: TimeInterval) async -> String {
        transport.drain()
        let attempted = Date()
        do {
            try await transport.write(command + "\r")
        } catch {
            linkFailure = error as? TransportError ?? .notOpen
            // Truthful numbers for the log: this exchange never happened.
            lastMs = Int(Date().timeIntervalSince(attempted) * 1000)
            lastStats = LinkStats()
            return ""
        }
        lastCommand = Date()
        let started = Date()
        let reply = await transport.read(until: ">", timeout: timeout)
        lastMs = Int(Date().timeIntervalSince(started) * 1000)
        lastStats = transport.stats
        return reply
    }
}
