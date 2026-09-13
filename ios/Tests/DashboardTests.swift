import XCTest

/// A dashboard must not cost a second read of anything.
///
/// The whole design rests on one claim: the list and the dashboards are two
/// views of one set of keys, so a parameter both of them show is read once,
/// kept once and written to the recording once. That claim is arithmetic on
/// sets and profile order, and this is where it is held to.
@MainActor
final class DashboardTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var profile: Profile!

    override func setUpWithError() throws {
        suite = "DashboardTests-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        profile = try Profile.bundled(in: Bundle(for: DashboardTests.self))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeSession(_ selection: SelectionStore? = nil) -> ElmSession {
        ElmSession(profile: profile,
                   makeAdapter: { _ in ElmAdapter(transport: ScriptedTransport()) },
                   selection: selection ?? SelectionStore(defaults: defaults))
    }

    private func page(_ id: String) throws -> Profile.Page {
        try XCTUnwrap(profile.pages.first { $0.id == id })
    }

    // MARK: - the store

    /// The shipped board is only worth shipping if every parameter on it still
    /// exists: the profile is regenerated from the Diagbox databases, and a
    /// first launch showing "нет в профиле" would be a poor introduction.
    func testTheShippedBoardNamesParametersTheProfileHas() throws {
        let known = ElmSession.allKeys(profile)
        let store = DashboardStore(defaults: defaults)
        let board = try XCTUnwrap(store.boards.first)
        XCTAssertFalse(board.tiles.isEmpty)
        for tile in board.tiles {
            XCTAssertTrue(known.contains(tile.key), "\(tile.key) is not in the profile")
        }
    }

    /// Every parameter on the shipped board comes from a page the default
    /// selection already reads, so the dashboard costs nothing on top of what
    /// the app polls anyway.
    func testTheShippedBoardAddsNoPageToTheCycle() throws {
        let store = DashboardStore(defaults: defaults)
        let session = makeSession()
        session.setDashboardKeys(store.keys)
        XCTAssertTrue(session.dashboardOnlyPages.isEmpty,
                      session.dashboardOnlyPages.compactMap(\.id).joined(separator: ", "))
    }

    func testABoardSurvivesARestart() throws {
        let store = DashboardStore(defaults: defaults)
        let board = Dashboard(name: "Расход", tiles: [
            Tile(key: "DEBIT_AIR", style: .graph, size: .wide, low: 0, high: 400),
        ])
        store.add(board)

        let reopened = DashboardStore(defaults: defaults)
        let saved = try XCTUnwrap(reopened.boards.first { $0.name == "Расход" })
        let tile = try XCTUnwrap(saved.tiles.first)
        XCTAssertEqual(tile.key, "DEBIT_AIR")
        XCTAssertEqual(tile.style, .graph)
        XCTAssertEqual(tile.size, .wide)
        XCTAssertEqual(tile.low, 0)
        XCTAssertEqual(tile.high, 400)
    }

    /// A reader who deleted every board meant it. The shipped one must not
    /// come back at the next launch as if nothing had happened.
    func testDeletingEveryBoardSticks() throws {
        let store = DashboardStore(defaults: defaults)
        for board in store.boards { store.remove(board.id) }
        XCTAssertTrue(store.boards.isEmpty)
        XCTAssertTrue(DashboardStore(defaults: defaults).boards.isEmpty)
    }

    /// The same parameter on two boards, and twice on one of them, is one key.
    func testTheKeysOfEveryBoardAreOneSet() throws {
        let store = DashboardStore(defaults: defaults)
        for board in store.boards { store.remove(board.id) }

        let first = Dashboard(name: "A", tiles: [
            Tile(key: "REGIME_MOTEUR", style: .gauge),
            Tile(key: "REGIME_MOTEUR", style: .graph),
            Tile(key: "VITESSE_VEHICULE"),
        ])
        let second = Dashboard(name: "B", tiles: [
            Tile(key: "REGIME_MOTEUR"),
            Tile(key: "DEBIT_AIR"),
        ])
        store.add(first)
        store.add(second)

        XCTAssertEqual(store.keys, ["REGIME_MOTEUR", "VITESSE_VEHICULE", "DEBIT_AIR"])
    }

    /// A layout saved by an older build, or by a newer one, must not be lost
    /// wholesale because of one field: the reader arranged it by hand.
    func testAnUnknownStyleFallsBackInsteadOfLosingTheBoard() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","name":"Старый","tiles":[
          {"key":"REGIME_MOTEUR","style":"hologram"},
          {"key":"VITESSE_VEHICULE","style":"gauge","size":"tall"}
        ]}]
        """
        defaults.set(Data(json.utf8), forKey: "dashboards")

        let store = DashboardStore(defaults: defaults)
        let board = try XCTUnwrap(store.boards.first)
        XCTAssertEqual(board.tiles.count, 2)
        XCTAssertEqual(board.tiles[0].style, .number, "an unknown style reads as a number")
        XCTAssertEqual(board.tiles[0].size, .small, "a missing size reads as small")
        XCTAssertEqual(board.tiles[1].style, .gauge)
        XCTAssertEqual(board.tiles[1].size, .tall)
    }

    func testTilesAreEditedInPlace() throws {
        let store = DashboardStore(defaults: defaults)
        let board = Dashboard(name: "A", tiles: [
            Tile(key: "REGIME_MOTEUR"),
            Tile(key: "VITESSE_VEHICULE"),
        ])
        store.add(board)

        var tile = try XCTUnwrap(store.board(board.id)?.tiles.first)
        tile.style = .bar
        store.update(tile, in: board.id)
        XCTAssertEqual(store.board(board.id)?.tiles.first?.style, .bar)

        store.move(tile.id, by: 1, in: board.id)
        XCTAssertEqual(store.board(board.id)?.tiles.map(\.key),
                       ["VITESSE_VEHICULE", "REGIME_MOTEUR"])
        store.move(tile.id, by: 1, in: board.id)
        XCTAssertEqual(store.board(board.id)?.tiles.map(\.key),
                       ["VITESSE_VEHICULE", "REGIME_MOTEUR"], "already last")

        store.removeTile(tile.id, from: board.id)
        XCTAssertEqual(store.board(board.id)?.tiles.map(\.key), ["VITESSE_VEHICULE"])
    }

    /// A copy has to be a copy: sharing tile identities would make the two
    /// boards edit each other.
    func testADuplicateSharesNoIdentity() throws {
        let store = DashboardStore(defaults: defaults)
        let board = Dashboard(name: "A", tiles: [Tile(key: "REGIME_MOTEUR")])
        store.add(board)
        let copy = try XCTUnwrap(store.duplicate(board.id))

        XCTAssertNotEqual(copy, board.id)
        let original = try XCTUnwrap(store.board(board.id)?.tiles.first?.id)
        let copied = try XCTUnwrap(store.board(copy)?.tiles.first?.id)
        XCTAssertNotEqual(original, copied)
    }

    // MARK: - what gets read

    /// The point of the whole design: two screens wanting a parameter are two
    /// members of one set.
    func testWhatIsPolledIsTheUnionOfTheListAndTheDashboards() throws {
        let session = makeSession()
        session.setSelection(["REGIME_MOTEUR"])
        session.setDashboardKeys(["REGIME_MOTEUR", "DEBIT_AIR"])

        XCTAssertEqual(session.polled, ["REGIME_MOTEUR", "DEBIT_AIR"])
        XCTAssertTrue(session.isSelected("REGIME_MOTEUR"))
        XCTAssertFalse(session.isSelected("DEBIT_AIR"), "the list's tick is the list's own")
    }

    /// The recording's columns. One per parameter however many tiles show it,
    /// and in profile order so a file written today drops into the same table
    /// as every earlier one.
    func testTheRecordingHasOneColumnPerParameterWhateverAsksForIt() throws {
        let session = makeSession()
        // Deliberately overlapping: the engine speed is in the list and on the
        // dashboards, the air flow only on the dashboards.
        session.setSelection(["REGIME_MOTEUR", "VITESSE_VEHICULE"])
        session.setDashboardKeys(["REGIME_MOTEUR", "DEBIT_AIR"])

        let keys = session.logKeys
        XCTAssertEqual(Set(keys), session.polled, "the columns are exactly what is read")
        XCTAssertEqual(keys.count, Set(keys).count, "no column twice")

        // Profile order: $C0's engine speed, then $C2's air flow, then $CA's
        // road speed - not the order they were named in.
        XCTAssertEqual(keys, ["REGIME_MOTEUR", "DEBIT_AIR", "VITESSE_VEHICULE"])
    }

    /// A page nothing is ticked from is still read if a tile shows it - and
    /// the screen has to be able to say so, or the switch looks broken.
    func testAPageHeldOnlyByADashboardStaysInTheCycle() throws {
        let session = makeSession()
        session.setSelection([])
        session.setDashboardKeys(["DEBIT_AIR"])

        let intake = try page("C2")
        XCTAssertEqual(session.polledPages.map(\.page.request), [intake.request])
        XCTAssertEqual(session.dashboardOnlyPages.compactMap(\.id), ["C2"])
        XCTAssertEqual(session.dashboardHolds(intake), 1)
        XCTAssertEqual(session.wantedOn(intake).wanted, 0, "the list's count is the list's own")
    }

    /// Reading only what is on the dashboards is the one lever that shortens a
    /// cycle, so it has to actually drop the rest.
    func testReadingOnlyTheDashboardsNarrowsTheSelection() throws {
        let session = makeSession()
        session.setDashboardKeys(["DEBIT_AIR"])
        session.readOnlyDashboards()
        XCTAssertEqual(session.polled, ["DEBIT_AIR"])
        XCTAssertEqual(session.logKeys, ["DEBIT_AIR"])

        // With nothing on the dashboards it must do nothing rather than leave
        // the app reading nothing at all.
        session.setDashboardKeys([])
        session.readOnlyDashboards()
        XCTAssertEqual(session.polled, ["DEBIT_AIR"])
    }

    // MARK: - the selection

    func testTheSelectionSurvivesARestart() throws {
        let store = SelectionStore(defaults: defaults)
        makeSession(store).setSelection(["REGIME_MOTEUR", "DEBIT_AIR"])

        XCTAssertEqual(makeSession(store).selected, ["REGIME_MOTEUR", "DEBIT_AIR"])
    }

    /// The profile is regenerated now and then; a key it no longer carries is
    /// dropped rather than kept asking for a page nothing can read.
    func testAStoredKeyTheProfileLostIsDropped() throws {
        defaults.set(["REGIME_MOTEUR", "SOMETHING_THE_PROFILE_DROPPED"],
                     forKey: "selectedParameters")
        XCTAssertEqual(makeSession().selected, ["REGIME_MOTEUR"])
    }

    /// An app that starts up reading nothing looks broken. Clearing the list is
    /// allowed; having it that way at the next launch is not.
    func testAnEmptyStoredSelectionFallsBackToTheDefault() throws {
        let store = SelectionStore(defaults: defaults)
        makeSession(store).setSelection([])
        XCTAssertEqual(makeSession(store).selected, ElmSession.defaultSelection(profile))
    }

    /// Nothing stored at all is the first launch: everything but the two
    /// static pages, exactly as before any of this existed.
    func testTheFirstLaunchSelectsWhatItAlwaysDid() throws {
        XCTAssertEqual(makeSession().selected, ElmSession.defaultSelection(profile))
        XCTAssertTrue(makeSession().dashboardKeys.isEmpty,
                      "the session learns about dashboards from the screen, not by itself")
    }
}
