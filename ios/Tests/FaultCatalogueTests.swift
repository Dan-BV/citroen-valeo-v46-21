import XCTest

/// The two generated files the whole-car fault screen stands on: the address
/// map it walks, and the dictionary that turns what comes back into words.
///
/// Both are produced from the Diagbox databases by `tools/diagbox`, so what is
/// checked here is not the wording - that is the database's - but that the app
/// and the generator still agree about the shape, and that the lookups land on
/// the module the reader is actually looking at.
final class FaultCatalogueTests: XCTestCase {

    private var bundle: Bundle { Bundle(for: FaultCatalogueTests.self) }

    private func loadScan() throws -> ScanProfile { try ScanProfile.bundled(in: bundle) }
    private func loadDictionary() throws -> DtcDictionary { try DtcDictionary.bundled(in: bundle) }
    private func loadProfile() throws -> Profile { try Profile.bundled(in: bundle) }

    // MARK: - the address map

    func testTheAddressMapCoversThePlatform() throws {
        let scan = try loadScan()
        XCTAssertEqual(scan.platform, "B7")
        XCTAssertGreaterThan(scan.targets.count, 40)
        // One walk per address, and every candidate of an address kept.
        let addresses = scan.byAddress
        XCTAssertEqual(addresses.reduce(0) { $0 + $1.targets.count }, scan.targets.count)
        XCTAssertEqual(Set(addresses.map { $0.address }).count, addresses.count)
    }

    func testTheEngineIsInTheMapWithItsFaultFrames() throws {
        let profile = try loadProfile()
        let scan = try loadScan()
        let engine = try XCTUnwrap(scan.targets.first { $0.request == profile.can.req })
        XCTAssertEqual(engine.response, profile.can.res)
        XCTAssertEqual(engine.faults?.request, "17FF00")
        XCTAssertEqual(engine.clear, "14FF00")
        // The engine answers KWP, whose records are code + status and whose
        // count byte bounds the list.
        let layout = try XCTUnwrap(engine.faults)
        XCTAssertTrue(layout.hasCount)
        XCTAssertNil(layout.failureTypeAt)
        XCTAssertFalse(layout.statusIsStandard)
    }

    /// Clearing one fault puts the fault itself where the "everything" group
    /// goes, so the width of that group has to match the module's own clear
    /// frame - two bytes on KWP, three on UDS.
    func testTheClearGroupWidthFollowsTheModulesOwnClearFrame() throws {
        let scan = try loadScan()
        for target in scan.targets {
            guard let clear = target.clear else { continue }
            XCTAssertTrue(clear.hasPrefix("14"), target.name)
            XCTAssertTrue(target.clearGroupBytes == 2 || target.clearGroupBytes == 3,
                          "\(target.name): \(clear)")
        }
    }

    /// Every fault layout has to describe records the parser can walk: the
    /// status byte inside the record, and the code before it.
    func testEveryFaultLayoutIsSelfConsistent() throws {
        let scan = try loadScan()
        for target in scan.targets {
            guard let layout = target.faults else { continue }
            XCTAssertGreaterThan(layout.record, 0, target.name)
            XCTAssertLessThan(layout.statusAt, layout.record, target.name)
            XCTAssertLessThanOrEqual(layout.codeAt + layout.codeLength,
                                     layout.statusAt, target.name)
            XCTAssertGreaterThan(layout.header, 0, target.name)
        }
    }

    // MARK: - the car's own modules

    /// The point of the map: a car answers on a fraction of the platform, and
    /// the rest is a minute of adapter timeouts. Once a full sweep has said
    /// which addresses are fitted, later sweeps walk only those.
    func testAFittedListNarrowsTheWalkToTheCarsOwnModules() throws {
        let scan = try loadScan()
        let profile = try loadProfile()
        let fitted = [profile.can.req: "V46_21", "744": "RBG_UDS"]

        let probes = scan.probes(fittedTo: fitted)
        XCTAssertEqual(probes.map { $0.address }, [profile.can.req, "744"])
        XCTAssertLessThan(probes.count, scan.byAddress.count / 10)
        // And only the candidate that answered, not all of an address's.
        let airbag = try XCTUnwrap(probes.first { $0.address == "744" })
        XCTAssertEqual(airbag.targets.map { $0.name }, ["RBG_UDS"])
    }

    /// The engine's address is ambiguous and the name stored for it is the
    /// profile's, which is none of the candidates. Dropping the address would
    /// lose the engine, so a name that matches nothing keeps every candidate.
    func testAStoredNameThatMatchesNoCandidateKeepsTheAddress() throws {
        let scan = try loadScan()
        let profile = try loadProfile()

        let probes = scan.probes(fittedTo: [profile.can.req: profile.ecu])
        let engine = try XCTUnwrap(probes.first)
        XCTAssertEqual(engine.address, profile.can.req)
        XCTAssertFalse(engine.targets.isEmpty)
    }

    /// The rule that a ThinkDiag broke on the car: it reaches one module, so a
    /// map made from its sweep would tell every later sweep - on any adapter -
    /// that this car has one module.
    func testOnlyASweepTheAdapterCouldCarryOutBecomesTheMap() throws {
        let scan = try loadScan()
        let engine = try XCTUnwrap(scan.targets.first)
        XCTAssertTrue(ScanSummary(full: true).mapsTheCar)
        XCTAssertFalse(ScanSummary(full: false).mapsTheCar,
                       "a short sweep walks the map, so it cannot rewrite it")
        XCTAssertFalse(ScanSummary(full: true, unreachable: [engine]).mapsTheCar)
        // Addresses nothing sits on are the normal case and say nothing about
        // the adapter: that sweep is exactly what the map is made of.
        XCTAssertTrue(ScanSummary(full: true, silent: [engine]).mapsTheCar)
    }

    func testTheInventorySurvivesARestart() throws {
        let suite = "EcuInventoryTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EcuInventoryStore(defaults: defaults)
        XCTAssertNil(store.load())

        let found = EcuInventory(present: ["6A8": "V46_21", "744": "RBG_UDS"],
                                 scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                 walked: 41)
        store.save(found)
        XCTAssertEqual(EcuInventoryStore(defaults: defaults).load(), found)

        store.forget()
        XCTAssertNil(store.load())
    }

    /// A sweep that found nothing says something about the ignition or the
    /// adapter, not about the car. Storing it would leave every later sweep
    /// walking an empty list and finding nothing for ever.
    func testAnEmptyInventoryIsNotStored() throws {
        let suite = "EcuInventoryTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EcuInventoryStore(defaults: defaults)
        store.save(EcuInventory(present: [:], scannedAt: Date(), walked: 41))
        XCTAssertNil(store.load())
    }

    // MARK: - the dictionary

    func testTheDictionaryNamesTheEnginesOwnCodes() throws {
        let profile = try loadProfile()
        let dictionary = try loadDictionary()
        let codes = try XCTUnwrap(dictionary.codes(forAnyOf: [profile.ecu]))
        // The engine's list travels in the profile as well, and the two are
        // generated from the same database rows.
        XCTAssertEqual(codes.count, profile.dtc.count)
        for (code, text) in profile.dtc {
            let entry = try XCTUnwrap(codes[code], code)
            XCTAssertEqual(dictionary.text(at: entry.textIndex), text, code)
        }
    }

    /// A UDS module's failure-type byte is what turns `$8001` into a sentence
    /// a person can act on, and the table is per code, not per ECU.
    func testAUdsCodeCarriesItsFailureTypes() throws {
        let dictionary = try loadDictionary()
        let codes = try XCTUnwrap(dictionary.codes(forAnyOf: ["ESP90"]))
        let entry = try XCTUnwrap(codes["0560"])
        XCTAssertNotNil(dictionary.text(at: entry.textIndex))
        XCTAssertNotNil(dictionary.failureType("11", of: entry))
        XCTAssertNil(dictionary.failureType("ZZ", of: entry))
    }

    func testModuleNamesAreInWords() throws {
        let dictionary = try loadDictionary()
        XCTAssertNotNil(dictionary.family("INJ"))
        XCTAssertNotNil(dictionary.family("ABRASR"))
        XCTAssertNil(dictionary.family("NOT_A_FAMILY"))
    }

    // MARK: - the two together

    /// The engine's address lists several candidate ECUs and the first of them
    /// is a diesel injection computer this car does not have. Looking the
    /// engine up by address would name its faults out of the wrong list, so the
    /// catalogue looks it up by the profile's own name instead.
    func testTheEngineIsNamedFromTheProfileNotFromTheAddressCandidates() throws {
        let profile = try loadProfile()
        let scan = try loadScan()
        let dictionary = try loadDictionary()
        let engine = try XCTUnwrap(scan.targets.first { $0.request == profile.can.req })
        XCTAssertNotEqual(engine.name, profile.ecu, "the address is ambiguous by design")

        let catalogue = FaultCatalogue(dictionary: dictionary,
                                       engineName: profile.ecu,
                                       engineRequest: profile.can.req)
        XCTAssertTrue(catalogue.isEngine(engine))
        XCTAssertEqual(catalogue.names(of: engine), [profile.ecu])

        let code = try XCTUnwrap(profile.dtc.keys.sorted().first)
        let detail = catalogue.detail(Dtc(code: code, status: "2F"), of: engine)
        XCTAssertEqual(detail.description, profile.dtc[code])
        // A KWP status byte has no published meaning, so it is shown raw.
        XCTAssertNil(detail.statusText)
        XCTAssertFalse(detail.present)
    }

    /// Without the dictionary the screen still works: the code stands in for
    /// the description and nothing throws.
    func testEverythingDegradesWithoutTheDictionary() throws {
        let profile = try loadProfile()
        let scan = try loadScan()
        let engine = try XCTUnwrap(scan.targets.first { $0.request == profile.can.req })
        let catalogue = FaultCatalogue(dictionary: nil,
                                       engineName: profile.ecu,
                                       engineRequest: profile.can.req)
        XCTAssertEqual(catalogue.title(of: engine), engine.family)
        let detail = catalogue.detail(Dtc(code: "0011", status: "2F"), of: engine)
        XCTAssertNil(detail.description)
        XCTAssertNil(detail.failureText)
    }
}
