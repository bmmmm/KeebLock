import AppKit
import SwiftUI

/// Compact teaser for the launcher: small image thumbnail + canonical title +
/// first-sentence summary. Tap the title to open the Wikipedia article. Sized
/// to slot under the codeword button without dominating the launcher.
struct CodewordCard: View {
    let codeword: String

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
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                titleRow
                Text(teaser)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: 380, alignment: .leading)
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
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        } else {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(.tint.opacity(0.12))
                .frame(width: 72, height: 72)
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary.opacity(0.5))
                )
        }
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(entry.title)
                .font(.headline)
                .foregroundStyle(.tint)
                .lineLimit(2)
            Spacer(minLength: 4)
            Link(destination: entry.wikipediaURL) {
                Image(systemName: "arrow.up.right.square")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .help("Open Wikipedia article")
        }
    }
}
