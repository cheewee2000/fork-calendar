import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a typed description ("dinner with Amy Friday 7pm Tokyo time at
/// Nobu, zoom.us/j/123") into event fields.
///
/// The on-device Apple Intelligence model only names the event and picks out
/// the place. It is small: asked for dates it returns none, it invents links
/// and venues, and its zone and all-day answers were wrong about one time in
/// three. So everything checkable is done in code — NSDataDetector finds the
/// day, time, zone and links in what was typed, "all day" is matched as
/// words, a place must literally appear in the text — and the clarifying
/// questions come from those checks, not from the model.
///
/// One assistant lives as long as its event panel, so an answer is read in
/// the context of what was typed before.
@MainActor
final class EventAssistant {
    struct Fields {
        var title: String?
        var start: Date?
        var end: Date?
        var allDay = false
        var timeZone: String?
        var location: String?
        var url: String?
        /// Non-nil when something must be answered before the event is right.
        var question: String?
    }

    /// The phrases the model extracts.
    struct Phrases {
        var title = ""
        var place = ""
    }

    /// Why the box can't be used on this machine, or nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This device doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to describe events in words."
            case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading its model."
            case .unavailable: return "Apple Intelligence is unavailable."
            }
        }
        #endif
        return "Describing events in words needs macOS 26 with Apple Intelligence."
    }

    private var session: Any?
    /// Everything typed so far (description, then answers).
    private var typed: [String] = []
    private var firstTitle: String?
    /// True while the panel applies a result (see the zone picker's onChange).
    var settingZone = false

    func fields(from text: String, defaultMinutes: Int) async throws -> Fields {
        typed.append(text)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let live: LanguageModelSession
            if let s = session as? LanguageModelSession {
                live = s
            } else {
                live = LanguageModelSession(instructions: Self.instructions)
                session = live
            }
            let d = try await live.respond(to: text, generating: Draft.self).content
            var phrases = Phrases(title: d.title, place: d.place)
            // The title comes from the description; on an answer the model
            // tends to retitle the event after the answer.
            if let first = firstTitle { phrases.title = first } else { firstTitle = d.title }
            return Self.resolve(phrases, typed: typed, defaultMinutes: defaultMinutes)
        }
        #endif
        return Fields(question: Self.unavailableReason)
    }

    static let instructions = """
    You name a calendar event and find its place. Copy words from the user; never add anything the user didn't write.
    A later message is a correction or an answer: return both parts again, with it merged in.
    Example: "dinner with Amy Friday 7-9pm Tokyo time at Nobu" gives title "Dinner with Amy", place "Nobu".
    Example: "offsite all day next Tuesday" gives title "Offsite", place "".
    Example: "flight to Seoul Dec 3 8pm" gives title "Flight to Seoul", place "".
    """

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    @Generable
    struct Draft {
        @Guide(description: "What the event is, without the day, time, zone, place or link.")
        var title: String
        @Guide(description: "The user's words for where it happens. Empty if they gave none.")
        var place: String
    }
    #endif

    // MARK: - Checked resolution (no model below this line)

    static func resolve(_ p: Phrases, typed: [String], defaultMinutes: Int, now: Date = Date()) -> Fields {
        let all = typed.joined(separator: " ")
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;")))
            return t.isEmpty || ["none", "null", "n/a", "empty"].contains(t.lowercased()) ? nil : t
        }
        let allDay = all.lowercased().range(of: #"\b(all|whole|full)[ -]day\b"#, options: .regularExpression) != nil
        // No usable title from the model: the description itself, trimmed
        // of its when/where words by finish().
        var out = Fields(title: clean(p.title) ?? typed.first, allDay: allDay)

        // Link: only one that was actually typed.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
           let link = detector.firstMatch(in: all, range: NSRange(all.startIndex..., in: all))?.url,
           link.scheme?.hasPrefix("http") == true {
            out.url = link.absoluteString
        }
        // Zone: "<city> time" / "<name> time" in the text. (The detector
        // reads most of these itself — "7pm Tokyo time", "9am PST" — and its
        // answer, taken below, wins.) A "… time" that names no zone is asked
        // about only when it looks like one ("Narnia time", not "lunch time").
        var zone: TimeZone?
        var zoneWords = ""
        if let r = all.range(of: #"\b([A-Za-z]+ )?[A-Za-z]+ time\b"#, options: .regularExpression) {
            let phrase = String(all[r])
            let lastTwo = phrase.split(separator: " ").suffix(2).joined(separator: " ")
            zone = timeZone(named: phrase) ?? timeZone(named: lastTwo)
            if zone != nil {
                zoneWords = phrase
            } else if lastTwo.first?.isUppercase == true {
                out.question = "Which time zone is “\(lastTwo)”?"
            }
        }

        // When: every date the detector finds in what was typed. A day in
        // one place and a clock time in another ("thursday" … "10am",
        // "9:30am PST on Monday") are one moment: day from the match without
        // a clock, time from the match with one.
        let clock = #"\d\s*(am|pm|a\.m|p\.m)\b|\d{1,2}:\d{2}|\b(noon|midnight|morning|afternoon|evening|tonight)\b|\bat \d"#
        let meridiem = #"\d\s*(am|pm|a\.m|p\.m)\b|\b(noon|midnight|morning|afternoon|evening|tonight)\b|\b(1[3-9]|2[0-3]):\d{2}"#
        func has(_ pattern: String, _ s: String) -> Bool {
            s.lowercased().range(of: pattern, options: .regularExpression) != nil
        }
        let matches = ((try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue))?
            .matches(in: all, range: NSRange(all.startIndex..., in: all)) ?? [])
            .filter { $0.date != nil }
            .map { (match: $0, text: Range($0.range, in: all).map { String(all[$0]) } ?? "") }
        // Place: only words the user typed after "at" / "@" / "in", and not
        // a piece of the date — the model offers "friday" and "3pm" as venues.
        let dateWords = Set(matches.map(\.text).joined(separator: " ").lowercased().split(separator: " ").map(String.init))
        if let place = clean(p.place), !place.contains("://"),
           !place.lowercased().split(separator: " ").allSatisfy({ dateWords.contains(String($0)) }),
           ["at ", "@ ", "@", "in "].contains(where: { all.localizedCaseInsensitiveContains($0 + place) }) {
            out.location = place
        }
        let timed = matches.last { has(clock, $0.text) }
        let dayOnly = matches.first { !has(clock, $0.text) }
        guard let main = timed ?? dayOnly, let mainDate = main.match.date else {
            out.question = out.question ?? "When is it?"
            return finish(out)
        }
        zone = main.match.timeZone ?? zone
        out.timeZone = zone?.identifier

        // Wall-clock components as typed, then placed in the event's zone.
        let local = Calendar.autoupdatingCurrent
        var typedCal = Calendar(identifier: .gregorian)
        typedCal.timeZone = main.match.timeZone ?? .autoupdatingCurrent
        var wall = typedCal.dateComponents([.year, .month, .day, .hour, .minute], from: mainDate)
        if timed != nil, let day = dayOnly?.match.date {
            let d = local.dateComponents([.year, .month, .day], from: day)
            (wall.year, wall.month, wall.day) = (d.year, d.month, d.day)
        }
        if allDay {
            let start = local.startOfDay(for: local.date(from: wall) ?? mainDate)
            out.start = start
            out.end = start.addingTimeInterval(max(main.match.duration, 86400))
            return finish(out)
        }
        var eventCal = Calendar(identifier: .gregorian)
        eventCal.timeZone = zone ?? .autoupdatingCurrent
        let start = eventCal.date(from: wall) ?? mainDate
        out.start = start
        out.end = start.addingTimeInterval(main.match.duration > 0 ? main.match.duration : Double(defaultMinutes) * 60)

        // A day with no clock time, or an hour that could be either half of
        // the day, is asked about rather than guessed.
        if timed == nil {
            out.question = out.question ?? "What time? (or say “all day”)"
        } else if !has(meridiem, all) {
            let hour = (wall.hour ?? 0) % 12
            out.question = out.question ?? "\(hour == 0 ? 12 : hour) AM or PM?"
        }
        return finish(out)

        /// The model often leaves the when/where words in the title.
        func finish(_ fields: Fields) -> Fields {
            var fields = fields
            guard var title = fields.title else { return fields }
            for cut in [fields.location ?? "", fields.url ?? ""] where !cut.isEmpty {
                title = title.replacingOccurrences(of: cut, with: " ", options: .caseInsensitive)
            }
            // Word by word: the model's title rarely holds the detector's
            // whole phrase ("Friday 7pm Tokyo time"), just pieces of it.
            let cut = Set((matches.map(\.text) + [zoneWords]).joined(separator: " ").lowercased().split(separator: " ").map(String.init))
                // The detector reads meals as times ("lunch tomorrow"); they're the title.
                .subtracting(["breakfast", "brunch", "lunch", "dinner", "supper", "coffee", "drinks",
                              "to", "at", "on", "in", "the", "from", "of", "a"])
            let stop: Set<String> = ["at", "on", "from", "in", "until", "till", "to", "all", "day", "@"]
            var words = title.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
                .filter { !cut.contains($0.lowercased()) }
            while let last = words.last, stop.contains(last.lowercased()) { words.removeLast() }
            while let first = words.first, stop.contains(first.lowercased()) { words.removeFirst() }
            fields.title = words.isEmpty ? nil : words.joined(separator: " ")
            return fields
        }
    }

    /// "PST", "Tokyo time", "pacific", "Europe/Paris", "London" → a zone.
    static func timeZone(named phrase: String) -> TimeZone? {
        var words = phrase.lowercased()
            .replacingOccurrences(of: #"\b(time|zone|timezone|local|in|the)\b"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        words = words.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !words.isEmpty else { return nil }
        let aliases = [
            "pacific": "America/Los_Angeles", "mountain": "America/Denver", "central": "America/Chicago",
            "eastern": "America/New_York", "uk": "Europe/London", "england": "Europe/London",
            "japan": "Asia/Tokyo", "korea": "Asia/Seoul", "india": "Asia/Kolkata", "china": "Asia/Shanghai",
            "beijing": "Asia/Shanghai", "san francisco": "America/Los_Angeles", "sf": "America/Los_Angeles",
            "la": "America/Los_Angeles", "nyc": "America/New_York", "new york": "America/New_York",
            "boston": "America/New_York", "seattle": "America/Los_Angeles", "minneapolis": "America/Chicago",
            "utc": "UTC", "gmt": "GMT",
        ]
        if let id = aliases[words] { return TimeZone(identifier: id) }
        if let z = TimeZone(abbreviation: words.uppercased()) { return z }
        let city = words.replacingOccurrences(of: " ", with: "_")
        return TimeZone.knownTimeZoneIdentifiers
            .first { $0.lowercased() == city || $0.lowercased().hasSuffix("/" + city) }
            .flatMap(TimeZone.init(identifier:))
    }
}

#if DEBUG
extension EventAssistant {
    /// Self-check of the code half: `EventAssistant.demo()`.
    static func demo() {
        assert(timeZone(named: "Tokyo time")?.identifier == "Asia/Tokyo")
        assert(timeZone(named: "PST") != nil && timeZone(named: "pacific time")?.identifier == "America/Los_Angeles")
        assert(timeZone(named: "Narnia") == nil)

        let text = "dinner with Amy Friday 7pm Tokyo time at Nobu, https://zoom.us/j/1"
        let ok = resolve(Phrases(title: "Dinner with Amy Friday 7pm", place: "Nobu"),
                         typed: [text], defaultMinutes: 60)
        assert(ok.title == "Dinner with Amy" && ok.question == nil && ok.timeZone == "Asia/Tokyo" && ok.location == "Nobu" && ok.url == "https://zoom.us/j/1")
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        assert(tokyo.component(.hour, from: ok.start!) == 19 && ok.end == ok.start!.addingTimeInterval(3600))

        // Invented place and link are dropped; missing date is asked about.
        let bad = resolve(Phrases(title: "Dentist", place: "Sam's house"), typed: ["dentist"], defaultMinutes: 60)
        assert(bad.location == nil && bad.url == nil && bad.question == "When is it?")
        // Ambiguous hour and missing time are asked about.
        assert(resolve(Phrases(title: "Call"), typed: ["call Friday at 7"], defaultMinutes: 60).question == "7 AM or PM?")
        assert(resolve(Phrases(title: "Call"), typed: ["call Friday"], defaultMinutes: 60).question?.hasPrefix("What time") == true)
        assert(resolve(Phrases(title: "Sync"), typed: ["sync Friday 3pm Narnia time"], defaultMinutes: 60).question?.contains("Narnia") == true)
        assert(resolve(Phrases(title: "Flight to Seoul", place: "friday"), typed: ["flight to Seoul friday 8pm to 11pm"], defaultMinutes: 60).title == "Flight to Seoul")
        assert(resolve(Phrases(title: "Call", place: "friday"), typed: ["call friday at 7pm"], defaultMinutes: 60).location == nil)
        assert(resolve(Phrases(), typed: ["lunch tomorrow noon to 1:30"], defaultMinutes: 60).title == "lunch")
        // A day and a time typed apart are one moment.
        let split = resolve(Phrases(title: "Coffee"), typed: ["coffee thursday", "10am at Blue Bottle"], defaultMinutes: 60)
        let c = Calendar.autoupdatingCurrent.dateComponents([.weekday, .hour], from: split.start!)
        assert(c.weekday == 5 && c.hour == 10 && split.question == nil)
        assert(resolve(Phrases(title: "Offsite"), typed: ["offsite all day next Tuesday"], defaultMinutes: 60).question == nil)
    }
}
#endif
