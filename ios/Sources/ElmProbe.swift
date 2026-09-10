import Foundation

/// The AT prefix of the ECU session, run on its own so the transport can be
/// proven against a real adapter before the whole session is ported.
///
/// The command list and the timeouts are the opening of `ElmSession.initEcu` in
/// the Android app, and `send` behaves like its counterpart there: drain first,
/// write the command with a carriage return, then read until the `>` prompt or
/// the timeout, whichever comes first.
@MainActor
final class ElmProbe: ObservableObject {

    struct Line: Identifiable {
        let id = UUID()
        let command: String
        let reply: String
        let ms: Int

        /// The adapter answered with something other than an echo of silence.
        var answered: Bool { !reply.isEmpty && !Frames.isError(reply) }
    }

    private static let sequence: [(String, TimeInterval)] = [
        ("ATZ", 2.5),    // reset; the banner that comes back names the firmware
        ("ATD", 0.8),    // defaults
        ("ATE0", 0.8),   // no echo
        ("ATL0", 0.8),   // no line feeds
        ("ATH0", 0.8),   // no headers
        ("ATS0", 0.8),   // no spaces
        ("ATAL", 0.8),   // allow long messages
        ("ATI", 0.8),    // identify, for the log
    ]

    /// What the handshake amounts to, for a screen that wants one line rather
    /// than the exchange.
    enum Verdict: Equatable {
        case unchecked
        case running
        /// An ELM327 answered; the payload is its `ATI` banner, "ELM327 v1.5".
        case elm(String)
        /// Something answered the AT commands, but did not call itself ELM327.
        case other(String)
        /// The link opened and every command timed out.
        case silent
        /// The link itself could not be opened.
        case failed(String)
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var running = false
    @Published private(set) var failure: String?
    @Published private(set) var connected = false

    var verdict: Verdict {
        if running { return .running }
        if let failure { return .failed(failure) }
        guard !lines.isEmpty else { return .unchecked }
        let answers = lines.filter(\.answered)
        guard let first = answers.first else { return .silent }
        // The banner comes back to ATZ as well as ATI, and a clone may garble
        // one of them, so take the first that names the chip.
        if let banner = answers.first(where: { $0.reply.uppercased().contains("ELM327") }) {
            return .elm(banner.reply)
        }
        return .other(first.reply)
    }

    private var transport: (any ElmTransport)?

    func run(_ config: TransportConfig) async {
        guard !running else { return }
        running = true
        failure = nil
        lines = []
        connected = false

        let transport = BleTransport(config: config)
        self.transport = transport

        do {
            try await transport.open()
            connected = true
            for (command, timeout) in Self.sequence {
                let started = Date()
                let reply = try await send(command, timeout: timeout, over: transport)
                lines.append(Line(command: command,
                                  reply: reply.isEmpty ? "-" : reply,
                                  ms: Int(Date().timeIntervalSince(started) * 1000)))
            }
        } catch {
            failure = error.localizedDescription
        }
        running = false
        // The check is over: leave the adapter free for the session.
        stop()
    }

    func stop() {
        transport?.close()
        transport = nil
        connected = false
    }

    private func send(_ command: String, timeout: TimeInterval,
                      over transport: any ElmTransport) async throws -> String {
        transport.drain()
        try await transport.write(command + "\r")
        let raw = await transport.read(until: ">", timeout: timeout)
        return raw
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }
}
