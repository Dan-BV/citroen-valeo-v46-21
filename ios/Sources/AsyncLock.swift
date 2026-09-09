import Foundation

/// Mutual exclusion that survives an `await`.
///
/// The Kotlin session guards the adapter with a Mutex, and its comment explains
/// why it is not a busy flag: the poll loop re-takes the lock in the same
/// breath it releases it, so a caller polling a flag would never catch it free.
/// A plain actor is not the equivalent here - an actor method that suspends
/// lets another call in (reentrancy), which would interleave two callers'
/// commands on the wire. This queues callers instead, and hands the adapter
/// over in the order they asked for it.
actor AsyncLock {
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            held = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// Runs `body` with the adapter to itself. `release` is explicit on both
    /// paths rather than in a `defer`, which cannot await. Declared `throws`
    /// and not `rethrows`: rethrows forbids throwing from a catch block, and
    /// the lock has to be handed back before the error travels on.
    nonisolated func locked<T>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }
}
