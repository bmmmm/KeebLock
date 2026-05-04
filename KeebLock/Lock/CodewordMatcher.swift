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
}
