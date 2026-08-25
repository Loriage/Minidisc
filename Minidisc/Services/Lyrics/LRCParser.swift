import Foundation

nonisolated struct ParsedLRCLine: Equatable, Sendable {
    let value: String
    let startMilliseconds: Int
}

nonisolated struct ParsedLRC: Equatable, Sendable {
    let lines: [ParsedLRCLine]
    let offsetMilliseconds: Int
}

/// Parses the line timestamps and optional global offset used by the LRC format.
nonisolated enum LRCParser {
    static func parse(_ source: String) -> ParsedLRC? {
        guard let timestampExpression = try? NSRegularExpression(
            pattern: #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
        ) else {
            return nil
        }

        var offset = 0
        var parsedLines: [(order: Int, line: ParsedLRCLine)] = []
        var order = 0

        for rawLine in source.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsedOffset = parseOffset(trimmed) {
                offset = parsedOffset
                continue
            }

            let fullRange = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = timestampExpression.matches(in: rawLine, range: fullRange)
            guard let lastMatch = matches.last,
                  let lastRange = Range(lastMatch.range, in: rawLine) else {
                continue
            }

            let value = String(rawLine[lastRange.upperBound...])
                .replacingOccurrences(
                    of: #"<\d{1,3}:\d{2}(?:[\.:]\d{1,3})?>"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            for match in matches {
                guard let start = startMilliseconds(for: match, in: rawLine) else { continue }
                parsedLines.append((order, ParsedLRCLine(value: value, startMilliseconds: start)))
                order += 1
            }
        }

        let lines = parsedLines
            .sorted {
                if $0.line.startMilliseconds == $1.line.startMilliseconds {
                    return $0.order < $1.order
                }
                return $0.line.startMilliseconds < $1.line.startMilliseconds
            }
            .map(\.line)
        guard !lines.isEmpty else { return nil }
        return ParsedLRC(lines: lines, offsetMilliseconds: offset)
    }

    private static func parseOffset(_ line: String) -> Int? {
        let lowercased = line.lowercased()
        guard lowercased.hasPrefix("[offset:"), line.hasSuffix("]") else { return nil }
        let start = line.index(line.startIndex, offsetBy: 8)
        let end = line.index(before: line.endIndex)
        return Int(line[start..<end].trimmingCharacters(in: .whitespaces))
    }

    private static func startMilliseconds(
        for match: NSTextCheckingResult,
        in source: String
    ) -> Int? {
        guard let minuteRange = Range(match.range(at: 1), in: source),
              let secondRange = Range(match.range(at: 2), in: source),
              let minutes = Int(source[minuteRange]),
              let seconds = Int(source[secondRange]),
              seconds < 60 else {
            return nil
        }

        var fractionMilliseconds = 0
        if match.range(at: 3).location != NSNotFound,
           let fractionRange = Range(match.range(at: 3), in: source) {
            let fraction = String(source[fractionRange])
            switch fraction.count {
            case 1: fractionMilliseconds = (Int(fraction) ?? 0) * 100
            case 2: fractionMilliseconds = (Int(fraction) ?? 0) * 10
            default: fractionMilliseconds = Int(fraction.prefix(3)) ?? 0
            }
        }

        return ((minutes * 60) + seconds) * 1_000 + fractionMilliseconds
    }
}
