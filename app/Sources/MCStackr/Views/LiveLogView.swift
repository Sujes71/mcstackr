import SwiftUI

// MARK: - Live log view

/// The log of a container or of a deployment, live.
///
/// Every line is a row of its own, with its parts coloured: the prefix of
/// the service, the timestamp and the level. The rows are not joined into
/// one text, so a line that arrives does not re-lay out the whole log, and
/// the scroll follows the stream without jumping.
struct LiveLogView: View {
    /// The lines of the log, oldest first.
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, raw in
                        LogRow(line: LogLine(id: index, raw: raw))
                            .id(index)
                    }

                    // The anchor the scroll follows: the end of the log.
                    Color.clear
                        .frame(height: 1)
                        .id(LiveLogView.bottomID)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .onChange(of: lines.count) { _, _ in
                // The scroll follows the last line, and only when the user
                // is already at the end: a log that is being read stays
                // where it is.
                withAnimation(.linear(duration: 0.12)) {
                    proxy.scrollTo(LiveLogView.bottomID, anchor: .bottom)
                }
            }
        }
    }

    static let bottomID = "live-log-bottom"
}

// MARK: - Log block

/// The output of an operation, with the same format the log of the app has.
///
/// It is the same row the live log draws, without the scroll: the output of
/// an operation is a fixed piece of text.
struct LogBlock: View {
    /// The lines of the output, oldest first.
    let lines: [String]
    /// How many lines it shows, when the output is long.
    var maxLines: Int? = nil
    /// The colour of the text of every line. A row draws its own colour, so
    /// the block has to carry it down.
    var messageColor: Color = Theme.text

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, raw in
                LogRow(line: LogLine(id: index, raw: raw), messageColor: messageColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shown: [String] {
        guard let maxLines else { return lines }
        return Array(lines.prefix(maxLines))
    }
}

// MARK: - Log row

/// One line of a log, split into the parts it shows with their own colour.
private struct LogRow: View {
    let line: LogLine
    var messageColor: Color = Theme.text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let prefix = line.prefix {
                Text(prefix)
                    .foregroundStyle(Theme.textDim)
            }
            if let timestamp = line.timestamp {
                Text(timestamp)
                    .foregroundStyle(Theme.info.opacity(0.85))
            }
            if let level = line.level {
                Text(level)
                    .foregroundStyle(levelColor(level))
                    .fontWeight(.semibold)
            }
            Text(line.message)
                .foregroundStyle(messageColor)
                .textSelection(.enabled)
        }
        .font(Theme.mono)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func levelColor(_ level: String) -> Color {
        switch level.uppercased() {
        case "ERROR", "FATAL", "PANIC": return Theme.danger
        case "WARN", "WARNING": return Theme.warning
        case "DEBUG", "TRACE": return Theme.textDim
        default: return Theme.running
        }
    }
}

// MARK: - Log line

/// A line of a log, split into the parts it has.
///
/// The logs of the app come in two shapes: the ones of a compose service,
/// which carry the prefix of the service (`api-1  | `), and the ones of a
/// deployment, which start with the timestamp. Both are understood.
struct LogLine {
    let id: Int
    /// The prefix of the service, when the line has one.
    let prefix: String?
    /// The timestamp of the line, when it has one.
    let timestamp: String?
    /// The level of the line, when it has one.
    let level: String?
    /// The rest of the line.
    let message: String

    init(id: Int, raw: String) {
        self.id = id
        var rest = raw

        // The prefix of a compose service: "api-1  | ".
        var prefix: String?
        if let range = rest.range(of: "  | ") {
            prefix = String(rest[rest.startIndex..<range.lowerBound])
            rest = String(rest[range.upperBound...])
        }

        // The timestamp: an ISO date at the start of the line.
        var timestamp: String?
        if let range = LogLine.timestampRange(rest) {
            timestamp = String(rest[rest.startIndex..<range.upperBound])
            rest = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        // The level: a word of the log that says how bad it is.
        var level: String?
        let levels = ["ERROR", "FATAL", "PANIC", "WARN", "WARNING", "NOTICE", "INFO", "DEBUG", "TRACE"]
        if let range = rest.range(of: #"^[A-Z]+"#) {
            let word = String(rest[range])
            if levels.contains(word) {
                level = word
                rest = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }

        self.prefix = prefix
        self.timestamp = timestamp
        self.level = level
        self.message = rest
    }

    /// The range of the timestamp at the start of a line, when it has one.
    private static func timestampRange(_ text: String) -> Range<String.Index>? {
        let pattern = #"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        guard let range = Range(match.range, in: text) else { return nil }
        return range
    }
}
