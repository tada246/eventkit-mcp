import EventKit
import EventKitCore
import Foundation

struct ListOut: Encodable {
    let name: String
    let id: String
    let source: String
    let isDefault: Bool
}

func cmdLists() throws {
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
    let alarms: [AlarmSpec]
}

func priorityLabel(_ p: Int) -> String {
    switch p {
    case 0: return "none"
    case 1...4: return "high"
    case 5: return "medium"
    case 6...9: return "low"
    default: return "invalid(\(p))"
    }
}

func dueDate(for reminder: EKReminder) -> Date? {
    reminder.dueDateComponents.flatMap(date(fromComponents:))
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
        completionDate: r.completionDate.map { isoFormatter.string(from: $0) },
        alarms: reminderAlarmSpecs(from: r.alarms, due: dueDate(for: r))
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

func cmdReminders(_ args: Args) throws {
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

struct CreateResult: Encodable {
    let created: ReminderOut
}

func cmdCreateReminder(_ args: Args) throws {
    requestRemindersAccess()
    let title = args.value("title") ?? args.positional.first
    guard let title, !title.isEmpty else {
        fail("usage: create-reminder --title <名前> [--list <名前>] [--due <ISO>] [--notes <メモ>] [--priority 0-9] [--alarms '<JSON>']")
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
    let dueRaw = args.value("due")
    let dueComponents = try dueRaw.map(parseDueComponents)
    if let dueComponents { reminder.dueDateComponents = dueComponents }
    if let p = args.value("priority") {
        guard let n = Int(p), (0...9).contains(n) else {
            fail("--priority must be 0-9 (0=none, 1-4=high, 5=medium, 6-9=low), got: \(p)")
        }
        reminder.priority = n
    }

    // 時刻付き期限で --alarms を省略したときは、期限ちょうどのアラームを既定で付ける。
    let specs: [AlarmSpec]
    if let raw = args.value("alarms") {
        specs = try parseAlarms(raw)
    } else if let dueRaw, !isDateOnly(dueRaw) {
        specs = [AlarmSpec(minutesBefore: 0)]
    } else {
        specs = []
    }
    let due = dueComponents.flatMap(date(fromComponents:))
    reminder.alarms = try makeReminderAlarms(specs, due: due)

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

func cmdCompleteReminder(_ args: Args) throws {
    requestRemindersAccess()
    guard let id = args.positional.first ?? args.value("id"), !id.isEmpty else {
        fail("usage: complete-reminder <ID>")
    }
    let reminder = try resolveReminder(id)
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

func resolveReminderIDs(_ args: Args) throws -> [String] {
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

func resolveReminder(_ id: String) throws -> EKReminder {
    guard let item = store.calendarItem(withIdentifier: id) else {
        throw CoreError("reminder not found: \(id)")
    }
    guard let reminder = item as? EKReminder else {
        throw CoreError("id \(id) is not a reminder (it is \(type(of: item)))")
    }
    return reminder
}

// 全件を commit: false で積んでから最後にまとめて commit する。
func commitBatch(_ body: () throws -> Void) {
    do {
        try body()
        try store.commit()
    } catch {
        store.reset()
        fail("save failed: \(error.localizedDescription)")
    }
}

struct UpdateRemindersResult: Encodable {
    let updated: [ReminderOut]
}

func cmdUpdateReminder(_ args: Args) throws {
    requestRemindersAccess()
    let ids = try resolveReminderIDs(args)
    let reminders = try ids.map(resolveReminder)

    let clear = args.clearFields()
    let clearable: Set<String> = ["due", "notes", "alarms"]
    let unsupported = clear.subtracting(clearable)
    guard unsupported.isEmpty else {
        throw CoreError("cannot clear reminder field(s): \(unsupported.sorted().joined(separator: ", "))")
    }

    let title = args.value("title")
    let listName = args.value("list")
    let newDue = try args.value("due").map(parseDueComponents)
    let newAlarms = try args.value("alarms").map(parseAlarms)
    let priority = try args.value("priority").map { raw -> Int in
        guard let n = Int(raw), (0...9).contains(n) else {
            throw CoreError("--priority must be 0-9 (0=none, 1-4=high, 5=medium, 6-9=low), got: \(raw)")
        }
        return n
    }
    let completed = try args.bool("completed")

    for reminder in reminders {
        if let title { reminder.title = title }
        if let listName { reminder.calendar = resolveLists(listName)[0] }
        if clear.contains("due") {
            reminder.dueDateComponents = nil
        } else if let newDue {
            reminder.dueDateComponents = newDue
        }
        if clear.contains("notes") {
            reminder.notes = nil
        } else if let notes = args.value("notes") {
            reminder.notes = notes
        }
        if let priority { reminder.priority = priority }
        if clear.contains("alarms") {
            reminder.alarms = []
        } else if let newAlarms {
            let due = clear.contains("due")
                ? nil
                : (newDue ?? reminder.dueDateComponents).flatMap(date(fromComponents:))
            reminder.alarms = try makeReminderAlarms(newAlarms, due: due)
        }
        if let completed {
            reminder.isCompleted = completed
            if !completed { reminder.completionDate = nil }
        }
    }

    commitBatch {
        for reminder in reminders { try store.save(reminder, commit: false) }
    }
    emit(UpdateRemindersResult(updated: reminders.map(serialize)))
}

struct DeleteRemindersResult: Encodable {
    let deleted: [ReminderOut]
}

func cmdDeleteReminder(_ args: Args) throws {
    requestRemindersAccess()
    let ids = try resolveReminderIDs(args)
    let reminders = try ids.map(resolveReminder)
    let deleted = reminders.map(serialize)
    commitBatch {
        for reminder in reminders { try store.remove(reminder, commit: false) }
    }
    emit(DeleteRemindersResult(deleted: deleted))
}

struct SearchResult: Encodable {
    let query: String
    let count: Int
    let includeCompleted: Bool
    let reminders: [ReminderOut]
}

func cmdSearch(_ args: Args) throws {
    requestRemindersAccess()
    let query = args.positional.first ?? ""
    let includeCompleted = args.has("include-completed")
    let calendars = args.value("list").map(resolveLists)
    let found = fetch(remindersPredicate(calendars: calendars, includeCompleted: includeCompleted))
    let matched: [EKReminder]
    if query.isEmpty {
        matched = found
    } else {
        // 日本語の濁点などで NFC/NFD が混在しうるので正規化してから比較する。
        let needle = query.precomposedStringWithCanonicalMapping.lowercased()
        matched = found.filter { r in
            let title = (r.title ?? "").precomposedStringWithCanonicalMapping.lowercased()
            let notes = (r.notes ?? "").precomposedStringWithCanonicalMapping.lowercased()
            return title.contains(needle) || notes.contains(needle)
        }
    }
    emit(SearchResult(
        query: query, count: matched.count,
        includeCompleted: includeCompleted, reminders: matched.map(serialize)))
}
