import XCTest

/// The parts of the transport that do not need an adapter: how a command is cut
/// up for BLE writes, and how a reply is assembled out of notification-sized
/// pieces. Both are places where a mistake is invisible until a page silently
/// reads half its fields.
final class TransportTests: XCTestCase {

    // MARK: - chunking

    func testCommandsShorterThanTheChunkGoOutInOnePiece() {
        let data = Data("ATZ\r".utf8)
        XCTAssertEqual(Chunker.chunks(data, size: Chunker.bleChunk), [data])
    }

    func testLongWritesAreCutAtTheChunkSize() {
        let data = Data(repeating: 0x41, count: 45)
        let chunks = Chunker.chunks(data, size: 20)
        XCTAssertEqual(chunks.map(\.count), [20, 20, 5])
        XCTAssertEqual(chunks.reduce(Data(), +), data, "nothing may be lost or reordered")
    }

    func testChunkingAnEmptyCommandWritesNothing() {
        XCTAssertEqual(Chunker.chunks(Data(), size: 20), [])
    }

    // MARK: - assembling a reply

    func testReplyIsHeldBackUntilThePromptArrives() {
        let buffer = ByteBuffer()
        buffer.append(Data("61FF04".utf8))
        XCTAssertNil(buffer.take(upTo: ">"), "an unfinished reply must not be handed out")

        buffer.append(Data("4F8F50\r>".utf8))
        XCTAssertEqual(buffer.take(upTo: ">"), "61FF044F8F50\r")
    }

    /// The adapter can answer faster than the reads: a second reply already in
    /// the buffer must survive the first one being taken.
    func testTwoRepliesInTheBufferComeOutSeparately() {
        let buffer = ByteBuffer()
        buffer.append(Data("OK\r>41 00 BE\r>".utf8))
        XCTAssertEqual(buffer.take(upTo: ">"), "OK\r")
        XCTAssertEqual(buffer.take(upTo: ">"), "41 00 BE\r")
        XCTAssertNil(buffer.take(upTo: ">"))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testTakeAllReturnsAnUnfinishedReply() {
        let buffer = ByteBuffer()
        buffer.append(Data("SEARCHING...".utf8))
        XCTAssertEqual(buffer.takeAll(), "SEARCHING...")
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainingLosesWhateverWasPending() {
        let buffer = ByteBuffer()
        buffer.append(Data("stale\r>".utf8))
        buffer.clear()
        XCTAssertNil(buffer.take(upTo: ">"))
    }

    // MARK: - waiting for data without a busy-wait

    // A read waits to be woken by the notification that carries the data. The
    // wakeup has to survive arriving early, arriving twice, and never arriving
    // at all, because CoreBluetooth does all three - and a wait that hangs
    // stalls the whole session, so these are load-bearing.

    func testAWakeupArrivingBeforeTheWaitIsNotLost() async {
        let buffer = ByteBuffer()
        buffer.append(Data("41 00>".utf8))

        let started = Date()
        await buffer.waitForData(upTo: 5)

        XCTAssertLessThan(Date().timeIntervalSince(started), 2,
                          "data was already there, so the wait had nothing to wait for")
    }

    func testDataArrivingWakesAParkedReader() async {
        let buffer = ByteBuffer()
        let started = Date()

        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            buffer.append(Data("41 00>".utf8))
        }
        await buffer.waitForData(upTo: 5)

        XCTAssertLessThan(Date().timeIntervalSince(started), 2,
                          "the append should have ended the wait, not the timeout")
        XCTAssertEqual(buffer.take(upTo: ">"), "41 00")
    }

    func testTheWaitGivesUpWhenNothingArrives() async {
        let buffer = ByteBuffer()
        let started = Date()

        await buffer.waitForData(upTo: 0.1)

        let took = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(took, 0.05, "it must not return before its timeout")
        XCTAssertLessThan(took, 3, "and it must return")
    }

    func testBeingWokenTwiceIsHarmless() async {
        let buffer = ByteBuffer()

        Task {
            try? await Task.sleep(nanoseconds: 20_000_000)
            buffer.append(Data("41 ".utf8))
            buffer.append(Data("00>".utf8))
        }
        await buffer.waitForData(upTo: 5)
        // A second wait proves the slot was left in a usable state; resuming a
        // continuation twice would already have crashed the process.
        await buffer.waitForData(upTo: 0.1)

        XCTAssertEqual(buffer.take(upTo: ">"), "41 00")
    }

    func testWaitingRepeatedlyKeepsWorking() async {
        let buffer = ByteBuffer()
        for i in 0..<5 {
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000)
                buffer.append(Data("\(i)>".utf8))
            }
            await buffer.waitForData(upTo: 5)
            XCTAssertEqual(buffer.take(upTo: ">"), "\(i)")
        }
    }

    // MARK: - the remembered adapter

    func testTheChosenAdapterSurvivesARestart() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AdapterStoreTests"))
        defaults.removePersistentDomain(forName: "AdapterStoreTests")

        let id = UUID()
        AdapterStore.save(.ble(id: id, name: "KONNWEI"), to: defaults)
        XCTAssertEqual(AdapterStore.load(defaults), .ble(id: id, name: "KONNWEI"))

        AdapterStore.forget(defaults)
        XCTAssertNil(AdapterStore.load(defaults))
    }
}
