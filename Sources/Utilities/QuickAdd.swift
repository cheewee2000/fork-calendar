import Foundation

/// Natural-language event parsing ("Lunch with Amy tomorrow at 1pm",
/// "Standup monday 9:30-10am") backed by NSDataDetector.
enum QuickAdd {
    struct Parsed {
        let title: String
        let start: Date
        let end: Date
    }

    static func parse(_ text: String, defaultDurationMinutes: Int) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return nil }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let matches = detector.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        guard let match = matches.first(where: { $0.date != nil }), let start = match.date else { return nil }

        let duration = match.duration > 0 ? match.duration : Double(defaultDurationMinutes) * 60

        var title = trimmed
        if let range = Range(match.range, in: title) {
            title.removeSubrange(range)
        }
        title = title
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.-–—@"))
        // Drop dangling connector words left behind ("Lunch at", "on Dinner")
        let stopWords: Set<String> = ["at", "on", "from", "in", "until", "till", "to"]
        var words = title.split(separator: " ").map(String.init)
        while let last = words.last, stopWords.contains(last.lowercased()) { words.removeLast() }
        while let first = words.first, stopWords.contains(first.lowercased()) { words.removeFirst() }
        title = words.joined(separator: " ")

        guard !title.isEmpty else { return nil }
        return Parsed(title: title, start: start, end: start.addingTimeInterval(duration))
    }
}
