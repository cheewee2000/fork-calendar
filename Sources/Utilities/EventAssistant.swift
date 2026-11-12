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
        var repeats: RecurrenceChoice?
        var invitees: [String] = []
        /// "google meet" was typed and no link was: make one on save.
        var meet = false
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
            var phrases = Phrases()
            do {
                let d = try await live.respond(to: text, generating: Draft.self).content
                phrases = Phrases(title: d.title, place: d.place)
            } catch {
                // The model refuses some harmless text ("pick up kids 3:15"
                // trips its safety guardrail) and its context can fill up.
                // The code half still reads everything but the place.
                session = nil
            }
            // The title comes from the description; on an answer the model
            // tends to retitle the event after the answer.
            if let first = firstTitle { phrases.title = first } else if !phrases.title.isEmpty { firstTitle = phrases.title }
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
        let lower = all.lowercased()
        func has(_ pattern: String, _ s: String) -> Bool {
            s.lowercased().range(of: pattern, options: .regularExpression) != nil
        }
        /// Every match of `pattern` in `s`, as [whole, group 1, …].
        func groups(_ pattern: String, _ s: String) -> [[String]] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
                (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
            }
        }
        var allDay = has(#"\b(all|whole|full)[ -]day\b"#, all)
        // The model's title only if every word of it was typed (it carries
        // names over from its instructions: "dinner friday" came back as
        // "Dinner with Amy"). Otherwise the description itself, trimmed of
        // its when/where words by finish().
        let modelTitle = clean(p.title).flatMap { t in
            t.lowercased().split(separator: " ").allSatisfy { lower.contains($0) } ? t : nil
        }
        var out = Fields(title: modelTitle ?? typed.first, allDay: allDay)
        /// Words finish() takes out of the title besides the date's.
        var extraCut: [String] = []

        // Links and email addresses: only ones that were actually typed.
        for link in ((try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue))?
            .matches(in: all, range: NSRange(all.startIndex..., in: all)) ?? []).compactMap(\.url) {
            if link.scheme == "mailto" {
                let email = String(link.absoluteString.dropFirst("mailto:".count))
                out.invitees.append(email)
                extraCut.append(email)
            } else if out.url == nil, link.scheme?.hasPrefix("http") == true {
                // A link typed without a scheme ("zoom.us/j/1") is read as http.
                let typedScheme = lower.contains("http://")
                out.url = typedScheme ? link.absoluteString
                    : link.absoluteString.replacingOccurrences(of: "http://", with: "https://")
                extraCut.append(link.absoluteString)
            }
        }
        if out.url == nil, let m = groups(#"\b(google meet|meet link)\b"#, lower).first {
            out.meet = true
            extraCut.append(m[0])
        }
        // Repeats: the panel's own choices, most specific first.
        let repeats: [(String, RecurrenceChoice)] = [
            (#"\b(every weekday|weekdays)\b"#, .weekdays),
            (#"\b(every (other|2|two) weeks?|biweekly|fortnightly)\b"#, .biweekly),
            (#"\b(every day|daily)\b"#, .daily),
            (#"\b(every week|weekly|every (mon|tue|wed|thu|fri|sat|sun)[a-z]*)\b"#, .weekly),
            (#"\b(every month|monthly)\b"#, .monthly),
            (#"\b(every year|yearly|annually|annual)\b"#, .yearly),
        ]
        for (pattern, choice) in repeats {
            guard let m = groups(pattern, lower).first else { continue }
            out.repeats = choice
            extraCut += ["every", "other"] + m[0].split(separator: " ").map(String.init).filter { $0.hasSuffix("ly") || $0.hasPrefix("weekday") }
            break
        }
        // "in 2 hours" is a start; any other "2 hours" / "45 min" is a length.
        var work = lower.replacingOccurrences(of: "half an hour", with: "30 minutes")
            .replacingOccurrences(of: #"\ban hour\b"#, with: "1 hour", options: .regularExpression)
        func seconds(_ g: [String]) -> Double { (Double(g[1]) ?? 0) * (g[2].hasPrefix("m") ? 60 : 3600) }
        var relative: Date?
        if let g = groups(#"\bin (\d+(?:\.\d+)?) ?(minutes?|mins?|hours?|hrs?)\b"#, work).first {
            // Rounded up to the next five minutes.
            relative = Date(timeIntervalSinceReferenceDate: ((now.timeIntervalSinceReferenceDate + seconds(g)) / 300).rounded(.up) * 300)
            work = work.replacingOccurrences(of: g[0], with: " ")
            extraCut += g[0].split(separator: " ").map(String.init)
        }
        let lengths = groups(#"\b(\d+(?:\.\d+)?) ?(hours?|hrs?|h|minutes?|mins?|m)\b"#, work)
        let typedLength = lengths.isEmpty ? nil : lengths.map(seconds).reduce(0, +)
        extraCut += lengths.flatMap { $0[0].split(separator: " ").map(String.init) + [$0[0], "an", "hour", "half"] }
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
        let dayWords = #"\b(mon|tue|wed|thu|fri|sat|sun|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|today|tonight|tomorrow|next|this)|\d{1,2}/\d{1,2}|\d(st|nd|rd|th)\b"#
        let matches = ((try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue))?
            .matches(in: all, range: NSRange(all.startIndex..., in: all)) ?? [])
            .filter { $0.date != nil }
            .map { (match: $0, text: Range($0.range, in: all).map { String(all[$0]) } ?? "") }
        // Place: only words the user typed after "at" / "@" / "in", and not
        // a piece of the date — the model offers "friday" and "3pm" as venues.
        let dateWords = Set(matches.map(\.text).joined(separator: " ").lowercased().split(separator: " ").map(String.init))
        // Without the model: capitalised words after "at".
        let place = clean(p.place) ?? groups(#"(?:\bat|@) ([A-Z][\w'’&]*(?: [A-Z&][\w'’&]*)*)"#, all).last?[1]
        if let place, !place.contains("://"),
           !place.lowercased().split(separator: " ").allSatisfy({ dateWords.contains(String($0)) }),
           ["at ", "@ ", "@", "in "].contains(where: { all.localizedCaseInsensitiveContains($0 + place) }) {
            out.location = place
        }
        // The latest clock time and the latest day win, so "make it 8pm"
        // keeps the day and "actually saturday" keeps the time.
        let timed = matches.last { has(clock, $0.text) }
        let dayMatch = matches.last { has(dayWords, $0.text) }
        let length = typedLength ?? Double(defaultMinutes) * 60
        guard let main = timed ?? dayMatch ?? matches.last, let mainDate = main.match.date else {
            if let relative {
                out.start = relative
                out.end = relative.addingTimeInterval(length)
            } else {
                out.question = out.question ?? "When is it?"
            }
            return finish(out)
        }
        zone = matches.reversed().compactMap(\.match.timeZone).first ?? zone
        out.timeZone = zone?.identifier

        // Wall-clock components as typed, then placed in the event's zone.
        func calendar(_ zone: TimeZone?) -> Calendar {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = zone ?? .autoupdatingCurrent
            return c
        }
        let local = Calendar.autoupdatingCurrent
        var wall = calendar(main.match.timeZone).dateComponents([.year, .month, .day, .hour, .minute], from: mainDate)
        if let day = dayMatch, day.match !== main.match, let date = day.match.date {
            let d = calendar(day.match.timeZone).dateComponents([.year, .month, .day], from: date)
            (wall.year, wall.month, wall.day) = (d.year, d.month, d.day)
        }
        // Whole days with no clock time ("Jan 5 to Jan 9") are all-day.
        if timed == nil, main.match.duration >= 86400 { allDay = true; out.allDay = true }
        if allDay {
            // The end is exclusive: "Dec 3-5" ends at the start of Dec 6.
            let start = local.startOfDay(for: local.date(from: wall) ?? mainDate)
            out.start = start
            out.end = local.date(byAdding: .day, value: Int((main.match.duration / 86400).rounded()) + 1, to: start)
            return finish(out)
        }
        let start = calendar(zone).date(from: wall) ?? mainDate
        out.start = start
        out.end = start.addingTimeInterval(main.match.duration > 0 ? main.match.duration : length)

        // A day with no clock time, or an hour that could be either half of
        // the day, is asked about rather than guessed.
        if timed == nil {
            out.question = out.question ?? "What time? (or say “all day”)"
        } else if !has(meridiem, all), let hour = wall.hour, hour % 12 != 0 {
            // (12 with no AM/PM is taken as noon.)
            out.question = out.question ?? "\(hour % 12) AM or PM?"
        }
        return finish(out)

        /// The model often leaves the when/where words in the title.
        func finish(_ fields: Fields) -> Fields {
            var fields = fields
            guard var title = fields.title else { return fields }
            for cut in [fields.location ?? "", fields.url ?? ""] + extraCut.filter({ $0.contains(".") || $0.contains(" ") }) where !cut.isEmpty {
                title = title.replacingOccurrences(of: cut, with: " ", options: .caseInsensitive)
            }
            // Word by word: the model's title rarely holds the detector's
            // whole phrase ("Friday 7pm Tokyo time"), just pieces of it.
            let cut = Set((matches.map(\.text) + [zoneWords] + extraCut).joined(separator: " ").lowercased().split(separator: " ").map(String.init))
                // The detector reads meals as times ("lunch tomorrow"); they're the title.
                .subtracting(["breakfast", "brunch", "lunch", "dinner", "supper", "coffee", "drinks",
                              "to", "at", "on", "in", "the", "from", "of", "a"])
            let stop: Set<String> = ["at", "on", "from", "in", "until", "till", "to", "for", "with", "all", "day", "@"]
            var words = title.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
                .filter { !cut.contains($0.lowercased()) }
            while let last = words.last, stop.contains(last.lowercased()) { words.removeLast() }
            while let first = words.first, stop.contains(first.lowercased()) { words.removeFirst() }
            // A title taken from the description starts lowercase.
            if let first = words.first, first == first.lowercased() { words[0] = first.prefix(1).uppercased() + first.dropFirst() }
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
        assert(resolve(Phrases(), typed: ["lunch tomorrow noon to 1:30"], defaultMinutes: 60).title == "Lunch")
        // A title with a word nobody typed is the model's invention.
        assert(resolve(Phrases(title: "Dinner with Amy"), typed: ["dinner friday 7pm"], defaultMinutes: 60).title == "Dinner")
        // Lengths, corrections, ranges, repeats, guests.
        let long = resolve(Phrases(), typed: ["meeting with Bob tomorrow 3pm for 2 hours at Nobu"], defaultMinutes: 60)
        assert(long.end == long.start!.addingTimeInterval(7200) && long.title == "Meeting with Bob" && long.location == "Nobu")
        let later = resolve(Phrases(title: "Dinner"), typed: ["dinner friday 7pm", "make it 8pm"], defaultMinutes: 60)
        let lc = Calendar.autoupdatingCurrent.dateComponents([.weekday, .hour], from: later.start!)
        assert(lc.weekday == 6 && lc.hour == 20)
        let moved = resolve(Phrases(title: "Dinner"), typed: ["dinner friday 7pm", "actually saturday"], defaultMinutes: 60)
        let mc = Calendar.autoupdatingCurrent.dateComponents([.weekday, .hour], from: moved.start!)
        assert(mc.weekday == 7 && mc.hour == 19)
        let range = resolve(Phrases(title: "Conference"), typed: ["conference Dec 3-5"], defaultMinutes: 60)
        assert(range.allDay && range.question == nil && Calendar.autoupdatingCurrent.component(.day, from: range.end!) == 6)
        let rep = resolve(Phrases(), typed: ["standup every weekday 9:30am, sam@example.com, google meet"], defaultMinutes: 60)
        assert(rep.repeats == .weekdays && rep.invitees == ["sam@example.com"] && rep.meet && rep.title == "Standup")
        let soon = resolve(Phrases(), typed: ["demo in 2 hours"], defaultMinutes: 60)
        assert(soon.question == nil && soon.title == "Demo" && soon.start! > Date().addingTimeInterval(7100))
        assert(resolve(Phrases(), typed: ["lunch 12/15 at 12:30"], defaultMinutes: 60).question == nil)
        assert(resolve(Phrases(), typed: ["sync monday 3pm zoom.us/j/9"], defaultMinutes: 60).url == "https://zoom.us/j/9")
        // A day and a time typed apart are one moment.
        let split = resolve(Phrases(title: "Coffee"), typed: ["coffee thursday", "10am at Blue Bottle"], defaultMinutes: 60)
        let c = Calendar.autoupdatingCurrent.dateComponents([.weekday, .hour], from: split.start!)
        assert(c.weekday == 5 && c.hour == 10 && split.question == nil)
        assert(resolve(Phrases(title: "Offsite"), typed: ["offsite all day next Tuesday"], defaultMinutes: 60).question == nil)
    }
}
#endif
