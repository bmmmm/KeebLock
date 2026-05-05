import AppKit
import SwiftUI

// Compact knowledge surface for the launcher. Header always visible, plus a row
// of "ghost" icons (de-emphasized when idle, brighten + scale on hover). Each
// icon reveals its corresponding text in a stable preview area below.
struct CodewordCard: View {
    let codeword: String

    @State private var hovered: HoverItem? = nil
    private enum HoverItem: Hashable {
        case summary
        case fact(Int)
        case wiki
    }

    private var entry: CodewordKnowledge {
        CodewordKnowledgeBase.entry(for: codeword)
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            ghostRow
            preview
        }
        .padding(14)
        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tint.opacity(0.15), lineWidth: 1)
        )
        .frame(maxWidth: 380)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.iconSymbol)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(entry.word.capitalized)
                .font(.headline)
            Spacer()
            Link(destination: entry.wikipediaURL) {
                Image(systemName: "globe")
                    .font(.callout)
                    .foregroundStyle(hovered == .wiki ? Color.accentColor : Color.secondary)
                    .scaleEffect(hovered == .wiki ? 1.1 : 1.0)
            }
            .help("Open in Wikipedia")
            .onHover { h in hovered = h ? .wiki : (hovered == .wiki ? nil : hovered) }
        }
    }

    private var ghostRow: some View {
        HStack(spacing: 22) {
            ghostIcon(systemName: "info.circle", item: .summary)
            ForEach(0..<min(entry.facts.count, 5), id: \.self) { i in
                ghostIcon(systemName: "\(i + 1).circle", item: .fact(i))
            }
        }
    }

    private func ghostIcon(systemName: String, item: HoverItem) -> some View {
        let active = (hovered == item)
        return Image(systemName: systemName)
            .font(.title3)
            .foregroundStyle(active ? Color.accentColor : Color.secondary.opacity(0.45))
            .scaleEffect(active ? 1.18 : 1.0)
            .onHover { h in hovered = h ? item : (hovered == item ? nil : hovered) }
            .animation(.easeInOut(duration: 0.15), value: active)
    }

    private var preview: some View {
        let text = revealText
        return Text(text)
            .font(.callout)
            .multilineTextAlignment(.leading)
            .frame(height: 56, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.secondary)
            .id(text)
            .animation(.easeInOut(duration: 0.15), value: text)
    }

    private var revealText: String {
        switch hovered {
        case .summary: return entry.summary
        case .fact(let i):
            guard i < entry.facts.count else { return entry.summary }
            return entry.facts[i]
        case .wiki: return "Open the Wikipedia article in your browser."
        case .none:
            return entry.facts.isEmpty
                ? entry.summary
                : "Hover the icons to reveal facts about “\(entry.word.capitalized)”."
        }
    }
}
