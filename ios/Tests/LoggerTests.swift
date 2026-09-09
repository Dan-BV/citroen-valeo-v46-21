import XCTest

/// The recording format is a contract, not a detail: `data/logs/README.md`
/// describes it and the drive analysis in `out/drives/` reads it, so a file
/// written on the phone has to be indistinguishable from an Android one.
final class LoggerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("logger-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sample(_ value: Double, valid: Bool = true) -> Sample {
        Sample(value: value, raw: Int(value), at: Date(), valid: valid)
    }

    private func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    // MARK: -

    func testTheHeaderAndRowsMatchTheAndroidFormat() throws {
        let logger = CsvLogger(directory: directory)
        try logger.start(keys: ["REGIME_MOTEUR", "TEMPERATURE_D_EAU_MOTEUR_d"])
        let url = try XCTUnwrap(logger.url)

        let at = Date(timeIntervalSince1970: 1_788_926_718.508)
        logger.log(at, [
            "REGIME_MOTEUR": sample(923),
            "TEMPERATURE_D_EAU_MOTEUR_d": sample(15),
        ])
        logger.flush()

        let rows = try lines(url)
        XCTAssertEqual(rows[0], "time_ms,iso,REGIME_MOTEUR,TEMPERATURE_D_EAU_MOTEUR_d")

        let cells = rows[1].split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(cells[0], "1788926718508", "Unix milliseconds")
        XCTAssertTrue(cells[1].hasPrefix("2026-"), "local ISO with milliseconds")
        XCTAssertEqual(cells[1].count, 23, "yyyy-MM-ddTHH:mm:ss.SSS")
        XCTAssertEqual(Double(cells[2]), 923)
        XCTAssertEqual(Double(cells[3]), 15)

        logger.stop()
    }

    /// An empty cell, not a zero: a zero would read as a measurement.
    func testAParameterWithNoValidReadingLeavesItsCellEmpty() throws {
        let logger = CsvLogger(directory: directory)
        try logger.start(keys: ["A", "B", "C"])
        let url = try XCTUnwrap(logger.url)

        logger.log(Date(), ["A": sample(1), "C": sample(0, valid: false)])
        logger.stop()

        let cells = try lines(url)[1].split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(cells.count, 5, "time, iso and three parameters")
        XCTAssertEqual(Double(cells[2]), 1)
        XCTAssertEqual(cells[3], "", "B was never in the cycle")
        XCTAssertEqual(cells[4], "", "C answered, but not validly")
    }

    func testColumnsKeepTheOrderTheyWereStartedWith() throws {
        let logger = CsvLogger(directory: directory)
        try logger.start(keys: ["Z", "A", "M"])
        let url = try XCTUnwrap(logger.url)
        logger.log(Date(), ["A": sample(1), "M": sample(2), "Z": sample(3)])
        logger.stop()

        let rows = try lines(url)
        XCTAssertEqual(rows[0], "time_ms,iso,Z,A,M")
        let cells = rows[1].split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual([Double(cells[2]), Double(cells[3]), Double(cells[4])], [3, 1, 2])
    }

    /// Every connect would otherwise leave a header-only file behind.
    func testARecordingWithNoRowsIsDeleted() throws {
        let logger = CsvLogger(directory: directory)
        try logger.start(keys: ["A"])
        let url = try XCTUnwrap(logger.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        logger.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(logger.url)
        XCTAssertTrue(CsvLogger.logs(in: directory).isEmpty)
    }

    func testRowsAreCountedAndTheFileSurvivesStopping() throws {
        let logger = CsvLogger(directory: directory)
        try logger.start(keys: ["A"])
        let url = try XCTUnwrap(logger.url)
        for i in 1...5 { logger.log(Date(), ["A": sample(Double(i))]) }
        XCTAssertEqual(logger.rows, 5)

        logger.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try lines(url).count, 6, "a header and five rows")
    }

    /// Sharing a file mid-drive has to show the rows written so far.
    func testFlushMakesRowsReadableWhileStillRecording() throws {
        let logger = CsvLogger(directory: directory)
        try logger.start(keys: ["A"])
        let url = try XCTUnwrap(logger.url)
        logger.log(Date(), ["A": sample(1)])
        logger.flush()

        XCTAssertEqual(try lines(url).count, 2)
        XCTAssertTrue(logger.isRunning)
        logger.stop()
    }

    func testStartingTwiceKeepsTheFirstRecording() throws {
        let logger = CsvLogger(directory: directory)
        try logger.start(keys: ["A"])
        let first = try XCTUnwrap(logger.url)
        try logger.start(keys: ["B"])
        XCTAssertEqual(logger.url, first)
        logger.log(Date(), ["A": sample(1)])
        logger.stop()
    }

    func testTheListHoldsOnlyRecordingsAndNewestFirst() throws {
        let stranger = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: stranger)

        var written: [URL] = []
        for i in 1...2 {
            let logger = CsvLogger(directory: directory)
            try logger.start(keys: ["A"])
            logger.log(Date(), ["A": sample(Double(i))])
            written.append(try XCTUnwrap(logger.url))
            logger.stop()
            // The file name carries whole seconds, so two starts in the same
            // second would land on one file.
            Thread.sleep(forTimeInterval: 1.05)
        }

        let listed = CsvLogger.logs(in: directory)
        XCTAssertEqual(listed.count, 2, "notes.txt is not a recording")
        XCTAssertEqual(listed.first, written.last, "newest first")
    }
}

/// The technical log is what tomorrow's drive is for: it has to record the
/// numbers that tell a slow serial link inside the adapter apart from a
/// notification-size ceiling, and it has to keep the drive log's timestamp
/// shape so both files line up on one timeline.
final class TechLogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tech-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    func testAnExchangeIsRecordedWithItsLinkCost() throws {
        let tech = TechLog(directory: directory)
        try tech.start()
        let url = try XCTUnwrap(tech.url)

        tech.log(TechLog.Exchange(
            at: Date(timeIntervalSince1970: 1_788_926_718.508),
            mode: "v4621",
            command: "21C08001",
            replyChars: 148,
            stats: LinkStats(notifications: 8, bytes: 152, largest: 20),
            ms: 243,
            ok: true,
            note: ""))
        tech.flush()

        let rows = try lines(url)
        XCTAssertEqual(rows[0], TechLog.header)

        let cells = rows[1].split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertEqual(cells[0], "1788926718508")
        XCTAssertEqual(cells[1].count, 23, "the same local ISO as the drive log")
        XCTAssertEqual(cells[2], "v4621")
        XCTAssertEqual(cells[3], "21C08001")
        XCTAssertEqual(cells[4], "148", "reply characters, which is what time scales with")
        XCTAssertEqual(cells[5], "8", "BLE pieces")
        XCTAssertEqual(cells[6], "152")
        XCTAssertEqual(cells[7], "20", "the largest piece is the MTU in practice")
        XCTAssertEqual(cells[8], "243")
        XCTAssertEqual(cells[9], "1")
        XCTAssertEqual(cells.count, 11, "the note column is there even when empty")

        tech.stop()
    }

    func testTheHeaderNamesEveryColumnItWrites() throws {
        let tech = TechLog(directory: directory)
        try tech.start()
        let url = try XCTUnwrap(tech.url)
        tech.log(TechLog.Exchange(at: Date(), mode: "obd", command: "010C050D",
                                 replyChars: 16, stats: LinkStats(notifications: 2, bytes: 24, largest: 20),
                                 ms: 61, ok: true, note: "multipid-refused"))
        tech.stop()

        let rows = try lines(url)
        let names = rows[0].split(separator: ",").count
        let values = rows[1].split(separator: ",", omittingEmptySubsequences: false).count
        XCTAssertEqual(names, values, "a header column for every value")
    }

    func testAMeasurementWithNoExchangesIsDeleted() throws {
        let tech = TechLog(directory: directory)
        try tech.start()
        let url = try XCTUnwrap(tech.url)
        tech.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDriveAndTechRecordingsAreListedApart() throws {
        let drive = CsvLogger(directory: directory)
        try drive.start(keys: ["A"])
        drive.log(Date(), ["A": Sample(value: 1, raw: 1, at: Date(), valid: true)])
        drive.stop()

        let tech = TechLog(directory: directory)
        try tech.start()
        tech.log(TechLog.Exchange(at: Date(), mode: "obd", command: "0100",
                                  replyChars: 8, stats: LinkStats(), ms: 30,
                                  ok: true, note: ""))
        tech.stop()

        XCTAssertEqual(CsvLogger.logs(in: directory).count, 1)
        XCTAssertEqual(TechLog.logs(in: directory).count, 1)
        XCTAssertTrue(try XCTUnwrap(CsvLogger.logs(in: directory).first)
            .lastPathComponent.hasPrefix(CsvLogger.prefix))
        XCTAssertTrue(try XCTUnwrap(TechLog.logs(in: directory).first)
            .lastPathComponent.hasPrefix(TechLog.prefix))
    }
}

/// The notification count is the whole point of the measurement, so the buffer
/// has to count what actually arrived, not what was asked for.
final class LinkStatsTests: XCTestCase {

    func testEachNotificationIsCountedWithItsSize() {
        let buffer = ByteBuffer()
        buffer.append(Data(repeating: 0x41, count: 20))
        buffer.append(Data(repeating: 0x42, count: 7))

        let stats = buffer.stats
        XCTAssertEqual(stats.notifications, 2)
        XCTAssertEqual(stats.bytes, 27)
        XCTAssertEqual(stats.largest, 20, "the ceiling the adapter actually uses")
    }

    func testDrainingResetsTheCountSoItDescribesOneReply() {
        let buffer = ByteBuffer()
        buffer.append(Data(repeating: 0x41, count: 20))
        buffer.clear()
        XCTAssertEqual(buffer.stats, LinkStats())
    }
}
