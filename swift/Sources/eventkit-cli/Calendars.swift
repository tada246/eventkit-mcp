import EventKit
import EventKitCore
import Foundation

struct CalendarOut: Encodable {
    let name: String
    let id: String
    let source: String
    let isDefault: Bool
    let allowsModify: Bool
    let color: String?
}

func cmdCalendars() throws {
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

// SDK によって EKEvent.startDate / endDate は Optional で import される。
func eventStart(_ e: EKEvent) -> Date {
    e.startDate ?? Date(timeIntervalSince1970: 0)
}

func eventEnd(_ e: EKEvent) -> Date {
    e.endDate ?? eventStart(e)
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
    let occurrence: String
    let recurrence: RecurrenceSpec?
    let alarms: [AlarmSpec]
}

func serialize(_ e: EKEvent) -> EventOut {
    EventOut(
        title: e.title ?? "",
        id: e.eventIdentifier ?? "",
        calendar: e.calendar?.title ?? "",
        start: formatEventDate(eventStart(e), allDay: e.isAllDay),
        end: formatEventDate(eventEnd(e), allDay: e.isAllDay),
        isAllDay: e.isAllDay,
        location: e.location,
        notes: e.hasNotes ? e.notes : nil,
        url: e.url?.absoluteString,
        isRecurring: e.hasRecurrenceRules,
        isDetached: e.isDetached,
        occurrence: formatEventDate(eventStart(e), allDay: e.isAllDay),
        recurrence: e.recurrenceRules?.first.map { recurrenceSpec(from: $0) },
        alarms: alarmSpecs(from: e.alarms)
    )
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
            let key = "\(e.eventIdentifier ?? "")|\(eventStart(e).timeIntervalSince1970)"
            if seen.insert(key).inserted { results.append(e) }
        }
        cursor = chunkEnd
    }
    return results.sorted { eventStart($0) < eventStart($1) }
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

func cmdEvents(_ args: Args) throws {
    requestCalendarAccess()
    let from = try parseDate(args.require("from"))
    let to = try parseDate(args.require("to"), endOfDay: true)
    guard from < to else { throw CoreError("--from must be before --to") }
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

func cmdSearchEvents(_ args: Args) throws {
    requestCalendarAccess()
    let query = args.positional.first ?? ""
    // EventKit にイベントの全文検索は無いので、期間で取ってから絞る。
    // 既定は前1年〜後2年。範囲は出力に明示する。
    let now = Date()
    let from = try args.value("from").map { try parseDate($0) }
        ?? gregorian.date(byAdding: .year, value: -1, to: now)!
    let to = try args.value("to").map { try parseDate($0, endOfDay: true) }
        ?? gregorian.date(byAdding: .year, value: 2, to: now)!
    let found = fetchEvents(from: from, to: to, calendars: nil)
    let matched: [EKEvent]
    if query.isEmpty {
        matched = found
    } else {
        let needle = query.precomposedStringWithCanonicalMapping.lowercased()
        matched = found.filter { e in
            let fields = [e.title, e.location, e.notes]
            return fields.contains { f in
                guard let f else { return false }
                return f.precomposedStringWithCanonicalMapping.lowercased().contains(needle)
            }
        }
    }
    emit(SearchEventsResult(
        query: query,
        from: isoFormatter.string(from: from),
        to: isoFormatter.string(from: to),
        count: matched.count,
        events: matched.map(serialize)))
}

func setAllDayDates(_ event: EKEvent, start: Date, inclusiveEnd: Date) {
    event.isAllDay = true
    event.startDate = start
    // all-day の endDate は「最終日の 0 時」を入れると、その日を含む期間として保存される（E2E で確認済み）。
    event.endDate = inclusiveEnd
}

struct CreateEventResult: Encodable {
    let created: EventOut
    let excludeNotFound: [String]?
}

func cmdCreateEvent(_ args: Args) throws {
    requestCalendarAccess()
    let title = args.value("title") ?? args.positional.first
    guard let title, !title.isEmpty else {
        fail("usage: create-event --title <名前> --start <ISO> [--end <ISO>] [--calendar <名前>] [--location <場所>] [--notes <メモ>] [--all-day true|false] [--alarms '<JSON>'] [--recurrence '<JSON>'] [--exclude '<JSON>']")
    }

    let startRaw = try args.require("start")
    let startIsDateOnly = isDateOnly(startRaw)
    let allDayFlag = try args.bool("all-day")
    // start が日付だけなら --all-day を省略しても終日として扱う。
    let allDay = startIsDateOnly || (allDayFlag ?? false)
    let start = try parseDate(startRaw)
    let end: Date
    if allDay {
        guard startIsDateOnly else {
            throw CoreError("all-day start must be yyyy-MM-dd")
        }
        if let endRaw = args.value("end") {
            guard isDateOnly(endRaw) else {
                throw CoreError("all-day end must be yyyy-MM-dd")
            }
            end = try allDayEndDate(start: start, inclusiveEnd: try parseDateOnly(endRaw))
        } else {
            end = start
        }
    } else {
        let endRaw = try args.require("end")
        end = try parseDate(endRaw)
        guard start <= end else { throw CoreError("--start must be before --end") }
    }

    let event = EKEvent(eventStore: store)
    event.title = title
    if allDay {
        setAllDayDates(event, start: start, inclusiveEnd: end)
    } else {
        event.isAllDay = false
        event.startDate = start
        event.endDate = end
    }

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
    if let raw = args.value("alarms") {
        event.alarms = try makeEventAlarms(try parseAlarms(raw))
    }
    if let raw = args.value("recurrence") {
        let spec = try parseRecurrence(raw)
        event.recurrenceRules = [try makeRecurrenceRule(spec, start: start)]
    }

    do {
        try store.save(event, span: .thisEvent, commit: true)
    } catch {
        fail("save failed: \(error.localizedDescription)")
    }

    var excludeNotFound: [String] = []
    if let raw = args.value("exclude") {
        let dates = try decodeJSON([String].self, from: raw, label: "exclude")
        excludeNotFound = try removeExcludedOccurrences(event, dates: dates)
    }
    emit(CreateEventResult(
        created: serialize(event),
        excludeNotFound: excludeNotFound.isEmpty ? nil : excludeNotFound))
}

func removeExcludedOccurrences(_ event: EKEvent, dates: [String]) throws -> [String] {
    // 繰り返しでないイベントには除外する回が無い。誤って本体を消さないように全部 notFound 扱いにする。
    guard event.hasRecurrenceRules else { return dates }
    var notFound: [String] = []
    for raw in dates {
        let day = try parseDate(raw)
        let from = gregorian.startOfDay(for: day)
        guard let to = gregorian.date(byAdding: .day, value: 1, to: from) else {
            notFound.append(raw)
            continue
        }
        let occurrences = fetchEvents(from: from, to: to, calendars: nil).filter {
            sameSeries($0, event.eventIdentifier)
        }
        if occurrences.isEmpty {
            notFound.append(raw)
            continue
        }
        do {
            for occurrence in occurrences {
                try store.remove(occurrence, span: .thisEvent, commit: false)
            }
            try store.commit()
        } catch {
            store.reset()
            fail("exclude failed for \(raw): \(error.localizedDescription)")
        }
    }
    return notFound
}

func resolveEventIDs(_ args: Args) throws -> [String] {
    let id = args.value("id")
    let idsRaw = args.value("ids")
    if id != nil && idsRaw != nil {
        throw CoreError("specify either --id or --ids, not both")
    }
    if let id, !id.isEmpty { return [id] }
    if let idsRaw {
        let ids = try decodeJSON([String].self, from: idsRaw, label: "ids")
        guard !ids.isEmpty else { throw CoreError("--ids must not be empty") }
        return ids
    }
    throw CoreError("specify --id <ID> or --ids '<JSON array>'")
}

// 出力の id は eventIdentifier なので calendarItem(withIdentifier:) では引けない。
// 繰り返しイベントはシリーズ最初の回が返る。
func resolveEvent(_ id: String) throws -> EKEvent {
    guard let event = store.event(withIdentifier: id) else {
        throw CoreError("event not found: \(id)")
    }
    return event
}

func parseSpan(_ args: Args) throws -> EKSpan? {
    guard let raw = args.value("span") else { return nil }
    switch raw {
    case "this": return .thisEvent
    case "future": return .futureEvents
    default: throw CoreError("--span must be this or future, got: \(raw)")
    }
}

// 1回だけ変更した回は独立した回になり、eventIdentifier の末尾に "/RID=…" が付く。
// シリーズの ID でもその回を探せるようにする。
func sameSeries(_ e: EKEvent, _ seriesID: String?) -> Bool {
    guard let seriesID, let id = e.eventIdentifier else { return false }
    let base = seriesID.components(separatedBy: "/RID=")[0]
    return id == base || id.hasPrefix(base + "/RID=")
}

func findOccurrence(eventID: String?, occurrence: String) throws -> EKEvent? {
    let target = try parseDate(occurrence)
    guard let from = gregorian.date(byAdding: .day, value: -1, to: target),
          let to = gregorian.date(byAdding: .day, value: 1, to: target) else {
        return nil
    }
    return fetchEvents(from: from, to: to, calendars: nil).first {
        sameSeries($0, eventID)
            && abs(eventStart($0).timeIntervalSince(target)) < 1
    }
}

struct EventTarget {
    let event: EKEvent
    let recurring: Bool
    let first: Bool
    let span: EKSpan
}

func resolveEventTarget(_ base: EKEvent, args: Args, occurrence: String?) throws -> EventTarget {
    guard base.hasRecurrenceRules else {
        if occurrence != nil {
            throw CoreError("event is not recurring; --occurrence is not allowed")
        }
        return EventTarget(event: base, recurring: false, first: true, span: .thisEvent)
    }

    let explicitSpan = try parseSpan(args)
    let target: EKEvent
    let first: Bool
    if let occurrence {
        guard let found = try findOccurrence(eventID: base.eventIdentifier, occurrence: occurrence) else {
            throw CoreError("occurrence not found: \(occurrence)")
        }
        target = found
        first = abs(eventStart(found).timeIntervalSince(eventStart(base))) < 1
    } else {
        // 繰り返しで occurrence を省略したときはシリーズ最初の回が対象。
        // this / future で影響範囲が大きく違うので span は暗黙に決めない。
        guard explicitSpan != nil else {
            throw CoreError("recurring event: specify --occurrence or --span this|future")
        }
        target = base
        first = true
    }
    return EventTarget(event: target, recurring: true, first: first, span: explicitSpan ?? .thisEvent)
}

func applyEventChanges(_ event: EKEvent, args: Args, clear: Set<String>) throws {
    if let title = args.value("title") { event.title = title }

    let allDayFlag = try args.bool("all-day")
    let startRaw = args.value("start")
    let endRaw = args.value("end")
    let startIsDateOnly = startRaw.map(isDateOnly) ?? false
    let allDay = startIsDateOnly || (allDayFlag ?? event.isAllDay)

    if allDay {
        var newStart = eventStart(event)
        if let startRaw {
            guard isDateOnly(startRaw) else {
                throw CoreError("all-day start must be yyyy-MM-dd")
            }
            newStart = try parseDateOnly(startRaw)
        } else if !event.isAllDay {
            newStart = gregorian.startOfDay(for: eventStart(event))
        }

        let inclusiveEnd: Date
        if let endRaw {
            guard isDateOnly(endRaw) else {
                throw CoreError("all-day end must be yyyy-MM-dd")
            }
            inclusiveEnd = try parseDateOnly(endRaw)
        } else if startRaw != nil {
            if event.isAllDay {
                // start だけ変えたときは日数を保って end もずらす。
                inclusiveEnd = newStart.addingTimeInterval(eventEnd(event).timeIntervalSince(eventStart(event)))
            } else {
                inclusiveEnd = newStart
            }
        } else if allDayFlag == true && !event.isAllDay {
            inclusiveEnd = newStart
        } else {
            inclusiveEnd = eventEnd(event)
        }
        setAllDayDates(event, start: newStart, inclusiveEnd: try allDayEndDate(start: newStart, inclusiveEnd: inclusiveEnd))
    } else {
        let newStart = try startRaw.map { try parseDate($0) } ?? eventStart(event)
        let newEnd: Date
        if let endRaw {
            newEnd = try parseDate(endRaw)
        } else if startRaw != nil {
            // start だけ変えたときは長さを保って end もずらす。
            newEnd = newStart.addingTimeInterval(eventEnd(event).timeIntervalSince(eventStart(event)))
        } else {
            newEnd = eventEnd(event)
        }
        guard newStart <= newEnd else { throw CoreError("--start must be before --end") }
        event.isAllDay = false
        event.startDate = newStart
        event.endDate = newEnd
    }

    if clear.contains("location") {
        event.location = nil
    } else if let location = args.value("location") {
        event.location = location
    }
    if clear.contains("notes") {
        event.notes = nil
    } else if let notes = args.value("notes") {
        event.notes = notes
    }
    if clear.contains("alarms") {
        event.alarms = []
    } else if let raw = args.value("alarms") {
        event.alarms = try makeEventAlarms(try parseAlarms(raw))
    }
    if clear.contains("recurrence") {
        event.recurrenceRules = nil
    } else if let raw = args.value("recurrence") {
        let spec = try parseRecurrence(raw)
        event.recurrenceRules = [try makeRecurrenceRule(spec, start: eventStart(event))]
    }
}

struct UpdateEventsResult: Encodable {
    let updated: [EventOut]
}

func cmdUpdateEvent(_ args: Args) throws {
    requestCalendarAccess()
    let ids = try resolveEventIDs(args)
    let occurrence = args.value("occurrence")
    if occurrence != nil && args.value("ids") != nil {
        throw CoreError("--occurrence cannot be used with --ids")
    }
    let bases = try ids.map(resolveEvent)
    let targets = try bases.map { try resolveEventTarget($0, args: args, occurrence: occurrence) }

    let clear = args.clearFields()
    let clearable: Set<String> = ["location", "notes", "alarms", "recurrence"]
    let unsupported = clear.subtracting(clearable)
    guard unsupported.isEmpty else {
        throw CoreError("cannot clear event field(s): \(unsupported.sorted().joined(separator: ", "))")
    }

    let calendarName = args.value("calendar")
    let newCalendar: EKCalendar? = calendarName.map { resolveCalendars($0)[0] }
    if let newCalendar {
        guard newCalendar.allowsContentModifications else { fail("calendar is read-only: \(calendarName ?? "")") }
        // カレンダー移動は EventKit の制約でシリーズ全体にしか効かない。
        for target in targets where target.recurring
            && target.event.calendar?.calendarIdentifier != newCalendar.calendarIdentifier {
            guard target.span == .futureEvents && target.first else {
                throw CoreError("moving a recurring event to another calendar requires --span future targeting the first occurrence")
            }
        }
    }

    for target in targets {
        try applyEventChanges(target.event, args: args, clear: clear)
        if let newCalendar {
            target.event.calendar = newCalendar
        }
    }

    commitBatch {
        for target in targets {
            try store.save(target.event, span: target.span, commit: false)
        }
    }
    emit(UpdateEventsResult(updated: targets.map { serialize($0.event) }))
}

struct DeleteEventsResult: Encodable {
    let deleted: [EventOut]
}

func cmdDeleteEvent(_ args: Args) throws {
    requestCalendarAccess()
    let ids = try resolveEventIDs(args)
    let occurrence = args.value("occurrence")
    if occurrence != nil && args.value("ids") != nil {
        throw CoreError("--occurrence cannot be used with --ids")
    }
    let bases = try ids.map(resolveEvent)
    let targets = try bases.map { try resolveEventTarget($0, args: args, occurrence: occurrence) }
    let deleted = targets.map { serialize($0.event) }
    commitBatch {
        for target in targets {
            try store.remove(target.event, span: target.span, commit: false)
        }
    }
    emit(DeleteEventsResult(deleted: deleted))
}
