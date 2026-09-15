import Foundation

/// One module as the whole-car sweep found it.
struct EcuNode: Identifiable, Equatable {
    let target: ScanProfile.Target
    /// The bytes the recognition frame answered with, after its fixed prefix.
    let identHex: String
    var faults: [Dtc]
    /// Set when the module answered the recognition frame but not the fault
    /// read. A refusal is worth showing; it is not "no faults".
    var failure: String?

    var id: String { target.id }
    /// Whether Diagbox describes a fault read for this module at all.
    var readable: Bool { target.faults != nil }
    var clearable: Bool { target.clear != nil && !faults.isEmpty }
}

/// What the sweep could not read, and why - kept apart from the modules it did
/// read so the screen can say "nothing there" and "cannot get there" with
/// different words.
struct ScanSummary: Equatable {
    /// Whether the whole platform was walked, or only the modules a previous
    /// sweep found fitted. A short sweep's silence means one known module did
    /// not answer, not that the rest of the car is absent.
    var full = true
    /// Addresses that answered nothing. Normal on a full sweep: the platform's
    /// map covers every variant of the car, and this one has a fraction of
    /// them fitted.
    var silent: [ScanProfile.Target] = []
    /// Addresses this adapter cannot speak to at all.
    var unreachable: [ScanProfile.Target] = []

    /// Whether this sweep is fit to be written down as the car's own module
    /// list. Only a full walk the adapter could actually carry out is: a
    /// ThinkDiag reaches one module, and a map made from its sweep would say
    /// this car has one module - to every later sweep, on any adapter.
    var mapsTheCar: Bool { full && unreachable.isEmpty }

    var silentFamilies: [String] { families(of: silent) }
    var unreachableFamilies: [String] { families(of: unreachable) }

    private func families(of targets: [ScanProfile.Target]) -> [String] {
        var seen = Set<String>()
        return targets.map(\.family).filter { seen.insert($0).inserted }
    }
}

/// Everything the databases can say about one stored fault.
struct FaultDetail {
    let dtc: Dtc
    /// The Diagbox description, or nil when the dictionary does not carry it.
    let description: String?
    /// What the failure-type byte means for this code, in this ECU's wording.
    let failureText: String?
    /// What the status byte means, when it is the standard UDS bit field.
    let statusText: String?
    /// Failing at this moment, as against stored from an earlier drive.
    let present: Bool
}

/// Names the modules and their faults, by looking them up in the platform
/// dictionary. Kept apart from `ElmSession` on purpose: the session's business
/// is what the ECU said, this one's is what it meant, and only one of the two
/// needs a 0.7 MB file.
struct FaultCatalogue {
    /// nil until the dictionary has loaded, and after a load that failed.
    /// Everything here degrades to the bare codes without it.
    var dictionary: DtcDictionary?
    /// The engine is the one module whose identity is not in doubt - the
    /// loaded profile names it - so it is looked up by that name rather than
    /// by its address, whose candidate list starts with a diesel ECU this car
    /// does not have.
    let engineName: String
    let engineRequest: String

    func isEngine(_ target: ScanProfile.Target) -> Bool {
        target.name == engineName || target.request == engineRequest
    }

    /// Every ECU this probe could have reached, as shown to the reader.
    func names(of target: ScanProfile.Target) -> [String] {
        isEngine(target) ? [engineName] : target.names
    }

    /// The module's name in words: what Diagbox calls the family, falling back
    /// to the family code when the dictionary has not loaded.
    func title(of target: ScanProfile.Target) -> String {
        dictionary?.family(target.family) ?? target.family
    }

    /// The line under the title: which ECU answered, and on what address.
    func subtitle(of target: ScanProfile.Target) -> String {
        var parts = [names(of: target).joined(separator: " / ")]
        if !target.request.isEmpty { parts.append(target.request + "/" + target.response) }
        parts.append(target.family)
        return parts.joined(separator: " · ")
    }

    func detail(_ dtc: Dtc, of target: ScanProfile.Target) -> FaultDetail {
        let layout = target.faults
        let entry = dictionary?.codes(forAnyOf: names(of: target))?[dtc.code]
        return FaultDetail(
            dtc: dtc,
            description: entry.flatMap { dictionary?.text(at: $0.textIndex) },
            failureText: dtc.failureType.isEmpty ? nil
                : entry.flatMap { dictionary?.failureType(dtc.failureType, of: $0) },
            statusText: layout.flatMap { Frames.dtcStatusText(dtc.status, $0) },
            present: layout.map { Frames.dtcIsPresent(dtc.status, $0) } ?? false)
    }
}
