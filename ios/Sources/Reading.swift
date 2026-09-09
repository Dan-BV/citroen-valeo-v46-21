import Foundation

extension Profile {
    /// What a field's bytes mean once decoded.
    enum Reading: Equatable {
        case number(Double)
        /// Raw value together with the text state the profile names for it,
        /// when it names one.
        case state(Int, label: String?)
        /// Identification values are packed digits, not numbers: `98 04 43 62 80`
        /// is PSA part number 9804436280.
        case hex(String)
    }
}

extension Profile.Field {
    /// Decode this field out of a cleaned reply. `nil` when the marker is
    /// absent or the answer is too short - i.e. a page the ECU did not answer.
    ///
    /// The order of operations here is the contract the parity fixture checks:
    /// bytes MSB first, then the bit field, then the kind.
    func read(_ cleanHex: String, marker: String) -> (raw: Int, reading: Profile.Reading)? {
        guard let digits = Frames.extractHex(cleanHex, marker: marker,
                                             offset: offset, length: length),
              var raw = Int(digits, radix: 16) else { return nil }

        if let mask {
            // Shift first, then mask, exactly like Field.compute in the Kotlin
            // app: the generator emits `m` as the mask of the already-shifted
            // value, so masking first would make a field like
            // TYPE_BOITE_VITESSES (m=3, sh=6) identically zero.
            raw = (raw >> (shift ?? 0)) & mask
        }
        if hex == true {
            return (raw, .hex(digits.uppercased()))
        }
        if let states {
            return (raw, .state(raw, label: states[String(raw)]))
        }
        return (raw, .number(Double(raw) * scale + delta))
    }
}

extension Profile.Page {
    /// Every field of this page that the reply actually carries.
    func read(_ cleanHex: String) -> [String: Profile.Reading] {
        var out: [String: Profile.Reading] = [:]
        out.reserveCapacity(params.count)
        for field in params {
            if let (_, reading) = field.read(cleanHex, marker: marker) {
                out[field.key] = reading
            }
        }
        return out
    }
}
