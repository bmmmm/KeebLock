import Testing
@testable import KeebLock

struct CleanmapCodecTests {

    // MARK: - decode

    @Test func decodeParsesValidKeycodes() {
        let decoded = CleanmapCodec.decode(["0": 3, "36": 7, "65535": 1])
        #expect(decoded == [0: 3, 36: 7, 65535: 1])
    }

    @Test func decodeDropsNonNumericKeys() {
        let decoded = CleanmapCodec.decode(["12": 5, "garbage": 9, "": 2])
        #expect(decoded == [12: 5])
    }

    @Test func decodeDropsKeysOutsideUInt16Range() {
        let decoded = CleanmapCodec.decode(["65536": 4, "-1": 6, "40": 8])
        #expect(decoded == [40: 8])
    }

    @Test func decodeEmptyDictYieldsEmpty() {
        #expect(CleanmapCodec.decode([:]).isEmpty)
    }

    // MARK: - encode

    @Test func encodeStringifiesKeycodes() {
        let encoded = CleanmapCodec.encode([0: 3, 36: 7, 65535: 1])
        #expect(encoded == ["0": 3, "36": 7, "65535": 1])
    }

    @Test func encodeEmptyDictYieldsEmpty() {
        #expect(CleanmapCodec.encode([:]).isEmpty)
    }

    // MARK: - roundtrip

    @Test func encodeDecodeRoundtripsLosslessly() {
        let original: [UInt16: Int] = [0: 1, 13: 250, 49: 9999, 65535: 42]
        #expect(CleanmapCodec.decode(CleanmapCodec.encode(original)) == original)
    }
}
