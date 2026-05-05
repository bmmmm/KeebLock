import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CleaningHistoryView: View {
    @ObservedObject var history: CleaningHistory = .shared
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var itemsPerPage: Int = 25
    @State private var currentPage: Int = 0
    private static let pageSizeOptions = [10, 25, 50, 100]

    private var sortedSessions: [CleaningSession] {
        history.sessions.sorted { $0.startedAt > $1.startedAt }
    }

    private var totalPages: Int {
        max(1, (sortedSessions.count + itemsPerPage - 1) / itemsPerPage)
    }

    private var pagedSessions: [CleaningSession] {
        let start = currentPage * itemsPerPage
        let end = min(start + itemsPerPage, sortedSessions.count)
        guard start < end else { return [] }
        return Array(sortedSessions[start..<end])
    }

    private var grouped: [(day: Date, sessions: [CleaningSession])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: pagedSessions) {
            cal.startOfDay(for: $0.startedAt)
        }
        return byDay.sorted { $0.key > $1.key }.map { (day: $0.key, sessions: $0.value) }
    }

    private var totalKeys: Int { history.sessions.reduce(0) { $0 + $1.keystrokeCount } }
    private var avgDurationSeconds: Int {
        guard !history.sessions.isEmpty else { return 0 }
        return history.sessions.reduce(0) { $0 + $1.durationSeconds } / history.sessions.count
    }
    private var todayCount: Int {
        let cal = Calendar.current
        return history.sessions.filter { cal.isDateInToday($0.startedAt) }.count
    }
    private var maxKeystrokesInSession: Int {
        history.sessions.map(\.keystrokeCount).max() ?? 1
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if history.sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        statsStrip
                        Divider()
                        activityChart
                        Divider()
                        sessionList
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 560)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cleaning History")
                    .font(.title2.weight(.semibold))
                if let last = history.lastWipe {
                    Text("Last wipe \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Stats strip

    private var statsStrip: some View {
        HStack(spacing: 0) {
            statCell("\(history.sessions.count)", label: "Sessions")
            Divider().frame(height: 40)
            statCell(formatNum(totalKeys), label: "Total keys")
            Divider().frame(height: 40)
            statCell(formatDur(avgDurationSeconds), label: "Avg duration")
            Divider().frame(height: 40)
            statCell("\(todayCount)", label: "Today")
        }
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.03))
    }

    private func statCell(_ value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 14-day activity chart

    private var activityChart: some View {
        let days = last14Days()
        let maxKeys = days.map(\.keystrokes).max().map { max(1, $0) } ?? 1

        return VStack(alignment: .leading, spacing: 10) {
            Text("14-DAY ACTIVITY")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 24)

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                    VStack(spacing: 5) {
                        let fraction = Double(day.keystrokes) / Double(maxKeys)
                        let active = day.keystrokes > 0

                        RoundedRectangle(cornerRadius: 4)
                            .fill(active
                                ? LinearGradient(
                                    colors: [
                                        settings.appTheme.color.opacity(0.5 + fraction * 0.5),
                                        settings.appTheme.color,
                                    ],
                                    startPoint: .bottom, endPoint: .top
                                  )
                                : LinearGradient(
                                    colors: [Color.primary.opacity(0.07)],
                                    startPoint: .bottom, endPoint: .top
                                  )
                            )
                            .frame(height: max(5, 72 * fraction))
                            .frame(maxWidth: .infinity, alignment: .bottom)

                        Text(chartDayLabel(day.date, index: i))
                            .font(.system(size: 9))
                            .foregroundStyle(Calendar.current.isDateInToday(day.date) ? settings.appTheme.color : .secondary)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 72 + 18)
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.015))
    }

    private func last14Days() -> [(date: Date, keystrokes: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<14).reversed().map { offset in
            // Calendar.date(byAdding:) returns nil only on a calendar-
            // arithmetic overflow, which can't happen for 14 days back
            // from today on the Gregorian calendar. Fall back to today
            // anyway so an unexpected nil doesn't crash the chart.
            let day = cal.date(byAdding: .day, value: -offset, to: today) ?? today
            let keys = history.sessions
                .filter { cal.isDate($0.startedAt, inSameDayAs: day) }
                .reduce(0) { $0 + $1.keystrokeCount }
            return (date: day, keystrokes: keys)
        }
    }

    private func chartDayLabel(_ date: Date, index: Int) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "T" }
        // show date number every 7 days and for the first bar
        if index == 0 || index % 7 == 0 {
            let f = DateFormatter()
            f.dateFormat = "d"
            return f.string(from: date)
        }
        return ""
    }

    // MARK: - Grouped session list

    private var sessionList: some View {
        LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
            ForEach(grouped, id: \.day) { group in
                Section {
                    ForEach(group.sessions) { session in
                        sessionRow(session)
                        if session.id != group.sessions.last?.id {
                            Divider()
                                .padding(.leading, 24)
                        }
                    }
                } header: {
                    dayHeader(group.day, count: group.sessions.count)
                }
            }
        }
    }

    private func dayHeader(_ day: Date, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(formatDayLabel(day))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.75))
            Text("·")
                .foregroundStyle(.secondary)
            Text("\(count) session\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
        .background(.regularMaterial)
    }

    private func sessionRow(_ session: CleaningSession) -> some View {
        HStack(spacing: 0) {
            // Time
            Text(formatTime(session.startedAt))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
                .padding(.leading, 24)

            // Duration column (text + mini bar)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.durationString)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.primary)
                GeometryReader { g in
                    let maxD = Double(history.sessions.map(\.durationSeconds).max() ?? 1)
                    let f = min(1, Double(session.durationSeconds) / maxD)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(settings.appTheme.color.opacity(0.45))
                        .frame(width: max(4, g.size.width * f), height: 3)
                }
                .frame(height: 3)
            }
            .frame(width: 88)
            .padding(.leading, 16)

            // Keys
            HStack(spacing: 5) {
                Image(systemName: "keyboard")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(session.keystrokeCount)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .frame(width: 80, alignment: .leading)
            .padding(.leading, 16)

            // Stages as dots
            HStack(spacing: 4) {
                ForEach(0..<min(session.stageCount, 8), id: \.self) { i in
                    Circle()
                        .fill(settings.appTheme.color.opacity(0.35 + Double(i) / Double(max(1, session.stageCount - 1)) * 0.55))
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: 80, alignment: .leading)
            .padding(.leading, 8)

            Spacer()
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No sessions recorded yet")
                .foregroundStyle(.secondary)
            Text("Start your first cleaning session to see stats here.")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                history.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.bordered)
            .disabled(history.sessions.isEmpty)

            if !history.sessions.isEmpty {
                Button {
                    exportJSON()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.system(size: 13))
                }
                .buttonStyle(.bordered)
                .help("Export all sessions as JSON")

                paginationControls
            }

            Spacer(minLength: 8)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    /// Open a save panel and write all sessions as JSON. Sessions are already
    /// Codable so the encoder does the work — no field-by-field formatting
    /// like CSV would need.
    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "keeblock-history-\(timestampStamp()).json"
        panel.title = "Export Cleaning History"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(history.sessions)
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func timestampStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private var paginationControls: some View {
        HStack(spacing: 10) {
            // Items-per-page picker
            Picker("", selection: $itemsPerPage) {
                ForEach(Self.pageSizeOptions, id: \.self) { n in
                    Text("\(n) / page").tag(n)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .onChange(of: itemsPerPage) { _, _ in currentPage = 0 }

            Divider().frame(height: 16)

            // Page navigation
            Button {
                if currentPage > 0 { currentPage -= 1 }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .disabled(currentPage == 0)

            Text("Page \(currentPage + 1) / \(totalPages)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 86)

            Button {
                if currentPage + 1 < totalPages { currentPage += 1 }
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.bordered)
            .disabled(currentPage + 1 >= totalPages)

            Divider().frame(height: 16)

            Text("\(history.sessions.count) total")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: history.sessions.count) { _, _ in
            // History grew/shrunk — clamp page in case currentPage now exceeds totalPages.
            if currentPage >= totalPages { currentPage = max(0, totalPages - 1) }
        }
    }

    // MARK: - Formatting

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func formatDayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMM"
        return f.string(from: date)
    }

    private func formatDur(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        if m == 0 { return "\(s)s" }
        return "\(m)m \(s)s"
    }

    private func formatNum(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
