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
