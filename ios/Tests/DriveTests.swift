import XCTest

/// The log list shows drives, not files, so the pairing has to get the two
/// recorders' files together - and keep apart what a retry a minute later
/// wrote.
final class DriveTests: XCTestCase {

    private func file(_ name: String, at seconds: TimeInterval,
                      lasting: TimeInterval = 600, bytes: Int = 1000) -> Drive.File {
        let started = Date(timeIntervalSince1970: 1_700_000_000 + seconds)
        return Drive.File(url: URL(fileURLWithPath: "/logs/" + name),
                          started: started,
                          modified: started.addingTimeInterval(lasting),
                          bytes: bytes)
    }

    func testTechAndLogSecondsApartAreOneDrive() {
        let drives = Drive.group([
            file("fap_log_20260910_134411.csv", at: 6),
            file("fap_tech_20260910_134405.csv", at: 0),
        ])
        XCTAssertEqual(drives.count, 1)
        XCTAssertTrue(drives[0].hasLog)
        XCTAssertTrue(drives[0].hasTech)
        XCTAssertEqual(drives[0].start, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(drives[0].bytes, 2000)
        XCTAssertEqual(drives[0].duration, 606, accuracy: 0.001)
    }

    func testTwoFilesOfTheSameKindAreTwoDrives() {
        // A connect that never reached the ECU leaves a tech file alone; the
        // retry twenty seconds later must not be folded into it.
        let drives = Drive.group([
            file("fap_tech_20260910_134405.csv", at: 0, lasting: 8),
            file("fap_tech_20260910_134425.csv", at: 20),
            file("fap_log_20260910_134431.csv", at: 26),
        ])
        XCTAssertEqual(drives.count, 2)
        XCTAssertEqual(drives.map(\.files.count), [2, 1], "newest first")
        XCTAssertFalse(drives[1].hasLog)
    }

    func testFilesFarApartAreSeparate() {
        let drives = Drive.group([
            file("fap_tech_20260910_134405.csv", at: 0),
            file("fap_log_20260910_135000.csv", at: 355),
        ])
        XCTAssertEqual(drives.count, 2)
    }

    func testStartIsReadFromTheName() throws {
        let url = URL(fileURLWithPath: "/logs/fap_log_20260910_134411.csv")
        let started = try XCTUnwrap(CsvFile.started(url))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                    from: started)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second],
                       [2026, 9, 10, 13, 44, 11])
        XCTAssertNil(CsvFile.started(URL(fileURLWithPath: "/logs/notes.csv")))
    }
}
