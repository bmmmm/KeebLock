import AppKit
import Foundation

/// One Wikipedia/Wikimedia entry for a codeword. Loaded from the bundled
/// codeword_data.json manifest at app start. Hand-curated entries are gone —
/// all data flows from the offline-fetched dataset under Resources/.
struct CodewordKnowledge {
    let word: String
    let title: String           // canonical Wikipedia title (e.g. "Mount Vesuvius")
    let summary: String         // first-paragraph extract
    let facts: [String]         // ~10 substantive paragraphs
    /// Short hand-curated "Did you know?" snippets — five per entry,
    /// designed for rotating display on the lock HUD. Falls back to
    /// `facts` when empty (older bundle versions or stub fallbacks).
    let didYouKnow: [String]
    let theme: String           // "volcanoes" / "rocks" / "minerals" / "phenomena" / "ranges"
    let imageFilename: String?  // resource filename in CodewordImages/, nil if unavailable
    let wikipediaURL: URL

    /// Resolves the bundled image to an NSImage, cached per session. Without
    /// the cache, SwiftUI body re-evaluations on every keystroke would trigger
    /// a fresh `NSImage(contentsOf:)` (disk read + JPEG decode) ~60× per second
    /// during fast typing — the source of the "buggy near codeword completion"
    /// lag. NSCache evicts under memory pressure, so worst case we reload.
    func loadImage() -> NSImage? {
        guard let name = imageFilename else { return nil }
        if let cached = CodewordKnowledgeBase.imageCache.object(forKey: name as NSString) {
            return cached
        }
        let stem = (name as NSString).deletingPathExtension
        let img: NSImage? = {
            if let asset = NSImage(named: stem) { return asset }
            if let url = Bundle.main.url(forResource: stem, withExtension: "jpg") {
                return NSImage(contentsOf: url)
            }
            return nil
        }()
        if let img {
            CodewordKnowledgeBase.imageCache.setObject(img, forKey: name as NSString)
        }
        return img
    }
}

/// Static accessor — one shared in-memory copy loaded eagerly at app launch.
enum CodewordKnowledgeBase {

    /// Per-session NSImage cache so we don't re-decode JPGs on every SwiftUI
    /// body re-evaluation.
    static let imageCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 32  // a handful of recent codeword images
        return c
    }()

    /// Words we have full data for. Keyed by lowercase word.
    static let entries: [String: CodewordKnowledge] = loadEntries()

    /// Returns the entry for a codeword. Falls back to a stub when the word
    /// isn't in the manifest — rare, since `Codewords.available` only offers
    /// words that have a real entry here.
    static func entry(for word: String) -> CodewordKnowledge {
        let key = word.lowercased()
        if let hit = entries[key] { return hit }
        // Stub fallback used only for codewords missing from the bundled
        // manifest. Falls back to the wikipedia home page if the
        // string-interpolated URL ever fails to parse.
        let fallbackURL = URL(string: "https://en.wikipedia.org/wiki/\(key.capitalized)")
            ?? URL(string: "https://en.wikipedia.org")
            ?? URL(fileURLWithPath: "/")
        return CodewordKnowledge(
            word: key,
            title: key.capitalized,
            summary: "No Wikipedia data bundled for this word.",
            facts: [],
            didYouKnow: [],
            theme: "unknown",
            imageFilename: nil,
            wikipediaURL: fallbackURL
        )
    }

    // MARK: - Loading

    private struct Manifest: Decodable {
        let data: [String: Entry]
        // The manifest also carries an `unavailable` array; we don't decode it
        // — codeword selection filters on real-entry presence (see
        // Codewords.available), which is robust even if the lists drift.

        struct Entry: Decodable {
            let title: String
            let summary: String
            let facts: [String]
            // Optional in the schema so older bundles (without the DYK
            // pipeline output) decode without errors. Newer bundles ship
            // five short snippets per entry under "did_you_know".
            let did_you_know: [String]?
            let theme: String
            let wikipedia_url: String
            let image_filename: String?
        }
    }

    /// Decoded once; `entries` and `unavailableWords` both read from this.
    /// They used to call `loadManifest()` independently, parsing the full
    /// JSON twice at launch.
    private static let manifest: Manifest? = loadManifest()

    private static func loadManifest() -> Manifest? {
        guard let url = Bundle.main.url(forResource: "codeword_data", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            DebugLog.log("CodewordKnowledgeBase: codeword_data.json not found in bundle")
            return nil
        }
        do {
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            DebugLog.log("CodewordKnowledgeBase: manifest decode failed: \(error)")
            return nil
        }
    }

    private static func loadEntries() -> [String: CodewordKnowledge] {
        guard let manifest else { return [:] }
        var out: [String: CodewordKnowledge] = [:]
        for (word, entry) in manifest.data {
            guard let url = URL(string: entry.wikipedia_url) else { continue }
            out[word.lowercased()] = CodewordKnowledge(
                word: word.lowercased(),
                title: entry.title,
                summary: entry.summary,
                facts: entry.facts,
                didYouKnow: entry.did_you_know ?? [],
                theme: entry.theme,
                imageFilename: entry.image_filename,
                wikipediaURL: url
            )
        }
        DebugLog.log("CodewordKnowledgeBase: loaded \(out.count) entries from manifest")
        return out
    }
}
