import Testing
@testable import KeebLock

struct CodewordMatcherTests {

    private func feedAll(_ matcher: inout CodewordMatcher, _ text: String) -> Bool {
        var matched = false
        for ch in text {
            matched = matcher.feed(ch)
        }
        return matched
    }

    // MARK: - feed

    @Test func matchesOnFinalCharacterOnly() {
        var m = CodewordMatcher(target: "volcano")
        for ch in "volcan" {
            #expect(m.feed(ch) == false)
        }
        #expect(m.feed("o") == true)
    }

    @Test func inputIsCaseInsensitive() {
        var m = CodewordMatcher(target: "volcano")
        #expect(feedAll(&m, "VOLCANO") == true)
    }

    @Test func targetIsNormalizedToLowercase() {
        var m = CodewordMatcher(target: "VOLCANO")
        #expect(feedAll(&m, "volcano") == true)
    }

    @Test func matchesAsTrailingWindowAfterNoise() {
        var m = CodewordMatcher(target: "volcano")
        #expect(feedAll(&m, "xxvolvolcano") == true)
    }

    @Test func mismatchAfterFullMatchRequiresFullRetype() {
        var m = CodewordMatcher(target: "abc")
        #expect(feedAll(&m, "abc") == true)
        #expect(m.feed("x") == false)
        #expect(feedAll(&m, "abc") == true)
    }

    @Test func emptyTargetNeverMatches() {
        var m = CodewordMatcher(target: "")
        #expect(m.feed("a") == false)
        #expect(m.matchProgress == 0)
    }

    // Character.lowercased() returns a String, not a Character — feed must
    // absorb whatever it yields without trapping. U+1E9E (uppercase ẞ)
    // lowercases to U+00DF (ß), so typing STRAẞE unlocks "straße".
    @Test func capitalSharpSLowercasesToSharpS() {
        var m = CodewordMatcher(target: "straße")
        #expect(feedAll(&m, "STRA\u{1E9E}E") == true)
    }

    @Test func bufferStaysTrimmedToTargetLength() {
        var m = CodewordMatcher(target: "ab")
        _ = feedAll(&m, "xyzxyzxyza")
        #expect(m.matchProgress == 1)
        #expect(m.feed("b") == true)
    }

    // MARK: - matchProgress

    @Test func progressStartsAtZero() {
        let m = CodewordMatcher(target: "volcano")
        #expect(m.matchProgress == 0)
    }

    @Test func progressTracksPrefix() {
        var m = CodewordMatcher(target: "volcano")
        _ = feedAll(&m, "vol")
        #expect(m.matchProgress == 3)
    }

    @Test func progressReachesCountOnFullMatch() {
        var m = CodewordMatcher(target: "volcano")
        _ = feedAll(&m, "volcano")
        #expect(m.matchProgress == 7)
    }

    @Test func progressDropsOnMismatch() {
        var m = CodewordMatcher(target: "volcano")
        _ = feedAll(&m, "volx")
        #expect(m.matchProgress == 0)
    }

    // KMP must keep the overlapping prefix alive across a partial mismatch:
    // after "abab" + "a" the live prefix of "abab" is "aba" (length 3).
    @Test func progressKeepsOverlappingPrefix() {
        var m = CodewordMatcher(target: "abab")
        _ = feedAll(&m, "ababa")
        #expect(m.matchProgress == 3)
    }

    @Test func progressWithRepeatedCharacters() {
        var m = CodewordMatcher(target: "aab")
        _ = feedAll(&m, "aaa")
        #expect(m.matchProgress == 2)
        #expect(m.feed("b") == true)
        #expect(m.matchProgress == 3)
    }
}
