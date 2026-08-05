import EventKit
import Foundation

struct CalendarOut: Encodable {
    let name: String
    let id: String
    let source: String
    let isDefault: Bool
    let allowsModify: Bool
    let color: String?
}

func cmdCalendars() {
    requestCalendarAccess()
    let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
    let out = store.calendars(for: .event).map { c in
        CalendarOut(
            name: c.title,
            id: c.calendarIdentifier,
            source: c.source.title,
            isDefault: c.calendarIdentifier == defaultID,
            allowsModify: c.allowsContentModifications,
            color: c.cgColor.map { cg in
                let comps = cg.components ?? []
                let v = comps.prefix(3).map { Int(($0 * 255).rounded()) }
                return v.count == 3 ? String(format: "#%02X%02X%02X", v[0], v[1], v[2]) : ""
            }
        )
    }
    emit(["calendars": out])
}

struct EventOut: Encodable {
    let title: String
    let id: String
    let calendar: String
    let start: String
    let end: String
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let url: String?
    let isRecurring: Bool
    let isDetached: Bool
}

func formatEventDate(_ d: Date, allDay: Bool) -> String {
    if allDay {
        let df = DateFormatter()
        df.calendar = gregorian
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: d)
    }
    return isoFormatter.string(from: d)
}

func serialize(_ e: EKEvent) -> EventOut {
    EventOut(
        title: e.title ?? "",
        id: e.eventIdentifier ?? "",
        calendar: e.calendar?.title ?? "",
        start: formatEventDate(e.startDate, allDay: e.isAllDay),
        end: formatEventDate(e.endDate, allDay: e.isAllDay),
        isAllDay: e.isAllDay,
        location: e.location,
        notes: e.hasNotes ? e.notes : nil,
        url: e.url?.absoluteString,
        isRecurring: e.hasRecurrenceRules,
        isDetached: e.isDetached
    )
}

func parseDate(_ s: String, endOfDay: Bool = false) -> Date {
    let df = DateFormatter()
    df.calendar = gregorian
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    if s.count == 10 && !s.contains("T") {
        df.dateFormat = "yyyy-MM-dd"
        guard let d = df.date(from: s) else { fail("bad date: \(s)") }
        return endOfDay ? d.addingTimeInterval(24 * 3600 - 1) : d
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    iso.timeZone = TimeZone.current
    if let d = iso.date(from: s) { return d }
    df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    guard let d = df.date(from: s) else {
        fail("bad date: \(s) (use yyyy-MM-dd or yyyy-MM-ddTHH:mm:ss)")
    }
    return d
}

// predicateForEvents は 4年を超える範囲を黙って先頭4年に切り詰めるので、
// 4年未満のウィンドウに分割して全部取る。
func fetchEvents(from: Date, to: Date, calendars: [EKCalendar]?) -> [EKEvent] {
    let window: TimeInterval = 3 * 365 * 24 * 3600
    var results: [EKEvent] = []
    var seen = Set<String>()
    var cursor = from
    while cursor < to {
        let chunkEnd = min(cursor.addingTimeInterval(window), to)
        let pred = store.predicateForEvents(withStart: cursor, end: chunkEnd, calendars: calendars)
        for e in store.events(matching: pred) {
            let key = "\(e.eventIdentifier ?? "")|\(e.startDate.timeIntervalSince1970)"
            if seen.insert(key).inserted { results.append(e) }
        }
        cursor = chunkEnd
    }
    return results.sorted { $0.startDate < $1.startDate }
}

func resolveCalendars(_ name: String) -> [EKCalendar] {
    let all = store.calendars(for: .event)
    let matched = all.filter { $0.title == name }
    if matched.isEmpty {
        fail("calendar not found: \(name). available: \(all.map(\.title).joined(separator: ", "))")
    }
    return matched
}

struct EventsResult: Encodable {
    let from: String
    let to: String
    let count: Int
    let events: [EventOut]
}

func cmdEvents(_ args: Args) {
    requestCalendarAccess()
    let from = parseDate(args.require("from"))
    let to = parseDate(args.require("to"), endOfDay: true)
    guard from < to else { fail("--from must be before --to") }
    let calendars = args.value("calendar").map(resolveCalendars)
    let found = fetchEvents(from: from, to: to, calendars: calendars)
    emit(EventsResult(
        from: isoFormatter.string(from: from),
        to: isoFormatter.string(from: to),
        count: found.count,
        events: found.map(serialize)))
}

struct SearchEventsResult: Encodable {
    let query: String
    let from: String
    let to: String
    let count: Int
    let events: [EventOut]
}

func cmdSearchEvents(_ args: Args) {
    requestCalendarAccess()
    guard let query = args.positional.first, !query.isEmpty else {
        fail("usage: search-events <文字列> [--from <ISO>] [--to <ISO>]")
    }
    // EventKit にイベントの全文検索は無いので、期間で取ってから絞る。
    // 既定は前1年〜後2年。範囲は出力に明示する。
    let now = Date()
    let from = args.value("from").map { parseDate($0) }
        ?? gregorian.date(byAdding: .year, value: -1, to: now)!
    let to = args.value("to").map { parseDate($0, endOfDay: true) }
        ?? gregorian.date(byAdding: .year, value: 2, to: now)!
    let needle = query.precomposedStringWithCanonicalMapping.lowercased()
    let matched = fetchEvents(from: from, to: to, calendars: nil).filter { e in
        let fields = [e.title, e.location, e.notes]
        return fields.contains { f in
            guard let f else { return false }
            return f.precomposedStringWithCanonicalMapping.lowercased().contains(needle)
        }
    }
    emit(SearchEventsResult(
        query: query,
        from: isoFormatter.string(from: from),
        to: isoFormatter.string(from: to),
        count: matched.count,
        events: matched.map(serialize)))
}

struct CreateEventResult: Encodable {
    let created: EventOut
}

func cmdCreateEvent(_ args: Args) {
    requestCalendarAccess()
    let title = args.value("title") ?? args.positional.first
    guard let title, !title.isEmpty else {
        fail("usage: create-event --title <名前> --start <ISO> --end <ISO> [--calendar <名前>] [--location <場所>] [--notes <メモ>] [--all-day]")
    }
    let event = EKEvent(eventStore: store)
    event.title = title
    let allDay = args.has("all-day")
    event.isAllDay = allDay
    event.startDate = parseDate(args.require("start"))
    event.endDate = parseDate(args.require("end"))
    guard event.startDate <= event.endDate else { fail("--start must be before --end") }

    if let name = args.value("calendar") {
        let cal = resolveCalendars(name)[0]
        guard cal.allowsContentModifications else { fail("calendar is read-only: \(name)") }
        event.calendar = cal
    } else if let def = store.defaultCalendarForNewEvents {
        event.calendar = def
    } else {
        fail("no default calendar; specify --calendar <名前>")
    }

    if let loc = args.value("location") { event.location = loc }
    if let notes = args.value("notes") { event.notes = notes }

    do {
        try store.save(event, span: .thisEvent, commit: true)
    } catch {
        fail("save failed: \(error.localizedDescription)")
    }
    emit(CreateEventResult(created: serialize(event)))
}
