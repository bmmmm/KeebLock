import Foundation

struct CodewordMatcher {
    private let target: String
    private let targetChars: [Character]
    private let failure: [Int]
    private var buffer: String = ""

    init(target: String) {
        let normalized = target.lowercased()
        self.target = normalized
        let chars = Array(normalized)
        self.targetChars = chars
        self.failure = Self.failureTable(chars)
    }

    /// Append a character; returns true if the buffer's tail equals the target.
    mutating func feed(_ char: Character) -> Bool {
        guard !target.isEmpty else { return false }
        // Character.lowercased() returns a String — for some Unicode inputs
        // (e.g. uppercase ẞ → "ss") that string spans multiple graphemes.
        // Append the whole lowercased string and trim by character count
        // afterwards; never construct Character(string) here, which traps
        // when the string isn't exactly one extended grapheme cluster.
        buffer.append(contentsOf: char.lowercased())
        while buffer.count > target.count {
            buffer.removeFirst()
        }
        return buffer == target
    }

    /// How many leading characters of `target` match the trailing characters of
    /// the current buffer. Ranges from 0 (no match) to target.count (full match).
    /// One O(buffer.count) KMP pass over the buffer against a precomputed failure
    /// table, replacing the former O(L²) suffix/prefix probe. `feed` keeps
    /// `buffer` trimmed to at most target.count, so `k` can only reach
    /// targetChars.count on the final character — it never indexes out of bounds.
    var matchProgress: Int {
        guard !targetChars.isEmpty, !buffer.isEmpty else { return 0 }
        var k = 0
        for ch in buffer {
            while k > 0 && ch != targetChars[k] { k = failure[k - 1] }
            if ch == targetChars[k] { k += 1 }
        }
        return k
    }

    /// KMP failure table: failure[i] = length of the longest proper prefix of
    /// targetChars[0...i] that is also a suffix. Built once per matcher.
    private static func failureTable(_ chars: [Character]) -> [Int] {
        guard !chars.isEmpty else { return [] }
        var table = [Int](repeating: 0, count: chars.count)
        var k = 0
        for i in 1..<chars.count {
            while k > 0 && chars[i] != chars[k] { k = table[k - 1] }
            if chars[i] == chars[k] { k += 1 }
            table[i] = k
        }
        return table
    }
}
