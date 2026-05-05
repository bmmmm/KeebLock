import Foundation

struct CodewordMatcher {
    private let target: String
    private var buffer: String = ""

    init(target: String) {
        self.target = target.lowercased()
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// Append a character; returns true if the buffer's tail equals the target.
    mutating func feed(_ char: Character) -> Bool {
        guard !target.isEmpty else { return false }
        let lower = Character(char.lowercased())
        buffer.append(lower)
        if buffer.count > target.count {
            buffer.removeFirst()
        }
        return buffer == target
    }

    /// How many leading characters of `target` match the trailing characters of
    /// the current buffer. Ranges from 0 (no match) to target.count (full match).
    var matchProgress: Int {
        guard !target.isEmpty, !buffer.isEmpty else { return 0 }
        let maxN = min(buffer.count, target.count)
        for n in stride(from: maxN, through: 1, by: -1) {
            if buffer.suffix(n) == target.prefix(n) { return n }
        }
        return 0
    }
}
