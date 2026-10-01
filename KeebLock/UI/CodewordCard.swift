import AppKit
import SwiftUI

/// Compact teaser for the launcher: small image thumbnail + canonical title +
/// first-sentence summary. Tap the title to open the Wikipedia article. Sized
/// to slot under the codeword button without dominating the launcher.
struct CodewordCard: View {
    let codeword: String

    @Environment(\.uiScale) private var uiScale

    private var entry: CodewordKnowledge {
        CodewordKnowledgeBase.entry(for: codeword)
    }

    /// First sentence of the summary, capped at ~140 chars so the card height
    /// stays predictable across short ("Granite is …") and long entries.
    private var teaser: String {
        let s = entry.summary
        if let dot = s.firstIndex(of: ".") {
            let candidate = String(s[..<dot]) + "."
            if candidate.count >= 30 { return candidate }
        }
        return s.count <= 140 ? s : String(s.prefix(140)).trimmingCharacters(in: .whitespaces) + "…"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12 * uiScale) {
            thumbnail
            VStack(alignment: .leading, spacing: 4 * uiScale) {
                titleRow
                Text(teaser)
                    .font(.system(size: 16 * uiScale))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12 * uiScale)
        .frame(maxWidth: 380 * uiScale, alignment: .leading)
        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(.tint.opacity(0.15), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = entry.loadImage() {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 72 * uiScale, height: 72 * uiScale)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        } else {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(.tint.opacity(0.12))
                .frame(width: 72 * uiScale, height: 72 * uiScale)
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary.opacity(0.5))
                )
        }
    }

    private var titleRow: some View {
        HStack(spacing: 6 * uiScale) {
            Text(entry.title)
                .font(.system(size: 20 * uiScale, weight: .semibold))
                .foregroundStyle(.tint)
                .lineLimit(2)
            Spacer(minLength: 4 * uiScale)
            Link(destination: entry.wikipediaURL) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 16 * uiScale))
                    .foregroundStyle(.secondary)
            }
            .help("Open Wikipedia article")
        }
    }
}
