import EventKit
import Foundation

struct ListOut: Encodable {
    let name: String
    let id: String
    let source: String
    let isDefault: Bool
}

func cmdLists() {
    requestRemindersAccess()
    let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
    let out = store.calendars(for: .reminder).map {
        ListOut(
            name: $0.title,
            id: $0.calendarIdentifier,
            source: $0.source.title,
            isDefault: $0.calendarIdentifier == defaultID
        )
    }
    emit(["lists": out])
}

struct ReminderOut: Encodable {
    let title: String
    let id: String
    let list: String
    let due: String?
    let dueAllDay: Bool?
    let notes: String?
    let priority: Int
    let priorityLabel: String
    let isCompleted: Bool
    let completionDate: String?
}

let gregorian = Calendar(identifier: .gregorian)

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone.current
    return f
}()

func priorityLabel(_ p: Int) -> String {
    switch p {
    case 0: return "none"
    case 1...4: return "high"
    case 5: return "medium"
    case 6...9: return "low"
    default: return "invalid(\(p))"
    }
}

// hour/minute が無い DateComponents は EventKit 上「終日」扱いになる。
func formatDue(_ dc: DateComponents?) -> (String?, Bool?) {
    guard let dc else { return (nil, nil) }
    let allDay = dc.hour == nil && dc.minute == nil
    var cal = gregorian
    if let tz = dc.timeZone { cal.timeZone = tz }
    guard let date = cal.date(from: dc) else { return (nil, allDay) }
    if allDay {
        let df = DateFormatter()
        df.calendar = gregorian
        df.timeZone = cal.timeZone
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return (df.string(from: date), true)
    }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = cal.timeZone
    return (f.string(from: date), false)
}

func serialize(_ r: EKReminder) -> ReminderOut {
    let (due, allDay) = formatDue(r.dueDateComponents)
    return ReminderOut(
        title: r.title ?? "",
        id: r.calendarItemIdentifier,
        list: r.calendar?.title ?? "",
        due: due,
        dueAllDay: allDay,
        notes: r.hasNotes ? r.notes : nil,
        priority: r.priority,
        priorityLabel: priorityLabel(r.priority),
        isCompleted: r.isCompleted,
        completionDate: r.completionDate.map { isoFormatter.string(from: $0) }
    )
}

func fetch(_ predicate: NSPredicate) -> [EKReminder] {
    let sem = DispatchSemaphore(value: 0)
    var result: [EKReminder]?
    _ = store.fetchReminders(matching: predicate) { found in
        result = found
        sem.signal()
    }
    if sem.wait(timeout: .now() + 60) == .timedOut {
        fail("fetchReminders timed out after 60s")
    }
    guard let result else { fail("fetchReminders returned nil (access revoked?)") }
    return result
}

func remindersPredicate(calendars: [EKCalendar]?, includeCompleted: Bool) -> NSPredicate {
    if includeCompleted {
        return store.predicateForReminders(in: calendars)
    }
    // 日付を渡すと期限なしのリマインダーが除外されるので両方 nil にする。
    return store.predicateForIncompleteReminders(
        withDueDateStarting: nil, ending: nil, calendars: calendars)
}

func resolveLists(_ name: String) -> [EKCalendar] {
    let all = store.calendars(for: .reminder)
    let matched = all.filter { $0.title == name }
    if matched.isEmpty {
        fail("list not found: \(name). available: \(all.map(\.title).joined(separator: ", "))")
    }
    return matched
}

func cmdReminders(_ args: Args) {
    requestRemindersAccess()
    let includeCompleted = args.has("include-completed")
    let calendars: [EKCalendar]?
    if let name = args.value("list") {
        calendars = resolveLists(name)
    } else if args.has("all") {
        calendars = nil  // nil = 全リスト
    } else {
        fail("specify --list <name> or --all")
    }
    let found = fetch(remindersPredicate(calendars: calendars, includeCompleted: includeCompleted))
    let out = found.map(serialize)
    emit(RemindersResult(count: out.count, includeCompleted: includeCompleted, reminders: out))
}

struct RemindersResult: Encodable {
    let count: Int
    let includeCompleted: Bool
    let reminders: [ReminderOut]
}

// 和暦ロケールだと Calendar.current が .japanese になり、
// dueDateComponents に入れると EventKit が例外を投げる。必ず gregorian を使う。
// hour/minute を入れないと EventKit 側で自動的に終日扱いになる。
func parseDue(_ s: String) -> DateComponents {
    let dateOnly = s.count == 10 && s.contains("-") && !s.contains("T")
    if dateOnly {
        let df = DateFormatter()
        df.calendar = gregorian
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd"
        guard let d = df.date(from: s) else { fail("bad --due date: \(s)") }
        return gregorian.dateComponents([.year, .month, .day], from: d)
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    iso.timeZone = TimeZone.current
    var date = iso.date(from: s)
    if date == nil {
        // タイムゾーン省略形 "2026-08-05T15:00:00" も受ける
        let df = DateFormatter()
        df.calendar = gregorian
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        date = df.date(from: s)
    }
    guard let date else { fail("bad --due datetime: \(s) (use yyyy-MM-dd or yyyy-MM-ddTHH:mm:ss)") }
    var dc = gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    dc.timeZone = TimeZone.current
    return dc
}

struct CreateResult: Encodable {
    let created: ReminderOut
}

func cmdCreateReminder(_ args: Args) {
    requestRemindersAccess()
    let title = args.value("title") ?? args.positional.first
    guard let title, !title.isEmpty else {
        fail("usage: create-reminder --title <名前> [--list <名前>] [--due <ISO>] [--notes <メモ>] [--priority 0-9]")
    }

    let reminder = EKReminder(eventStore: store)
    reminder.title = title

    if let listName = args.value("list") {
        reminder.calendar = resolveLists(listName)[0]
    } else if let def = store.defaultCalendarForNewReminders() {
        reminder.calendar = def
    } else {
        fail("no default reminder list; specify --list <名前>")
    }

    if let notes = args.value("notes") { reminder.notes = notes }
    if let due = args.value("due") { reminder.dueDateComponents = parseDue(due) }
    if let p = args.value("priority") {
        guard let n = Int(p), (0...9).contains(n) else {
            fail("--priority must be 0-9 (0=none, 1-4=high, 5=medium, 6-9=low), got: \(p)")
        }
        reminder.priority = n
    }

    do {
        try store.save(reminder, commit: true)
    } catch {
        fail("save failed: \(error.localizedDescription)")
    }
    emit(CreateResult(created: serialize(reminder)))
}

struct CompleteResult: Encodable {
    let completed: ReminderOut
}

func cmdCompleteReminder(_ args: Args) {
    requestRemindersAccess()
    guard let id = args.positional.first ?? args.value("id"), !id.isEmpty else {
        fail("usage: complete-reminder <ID>")
    }
    guard let item = store.calendarItem(withIdentifier: id) else {
        fail("reminder not found: \(id)")
    }
    guard let reminder = item as? EKReminder else {
        fail("id \(id) is not a reminder (it is \(type(of: item)))")
    }
    if reminder.isCompleted {
        fail("already completed: \(reminder.title ?? "")")
    }
    reminder.isCompleted = true
    do {
        try store.save(reminder, commit: true)
    } catch {
        fail("save failed: \(error.localizedDescription)")
    }
    emit(CompleteResult(completed: serialize(reminder)))
}

struct SearchResult: Encodable {
    let query: String
    let count: Int
    let includeCompleted: Bool
    let reminders: [ReminderOut]
}

func cmdSearch(_ args: Args) {
    requestRemindersAccess()
    guard let query = args.positional.first, !query.isEmpty else {
        fail("usage: search <文字列> [--include-completed] [--list <名前>]")
    }
    let includeCompleted = args.has("include-completed")
    let calendars = args.value("list").map(resolveLists)
    let found = fetch(remindersPredicate(calendars: calendars, includeCompleted: includeCompleted))
    // 日本語の濁点などで NFC/NFD が混在しうるので正規化してから比較する。
    let needle = query.precomposedStringWithCanonicalMapping.lowercased()
    let matched = found.filter { r in
        let title = (r.title ?? "").precomposedStringWithCanonicalMapping.lowercased()
        let notes = (r.notes ?? "").precomposedStringWithCanonicalMapping.lowercased()
        return title.contains(needle) || notes.contains(needle)
    }
    emit(SearchResult(
        query: query, count: matched.count,
        includeCompleted: includeCompleted, reminders: matched.map(serialize)))
}
