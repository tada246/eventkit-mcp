import EventKit
import Foundation

public let gregorian = Calendar(identifier: .gregorian)

public let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone.current
    return f
}()

public func isDateOnly(_ s: String) -> Bool {
    s.count == 10 && !s.contains("T")
}

public func parseDate(_ s: String, endOfDay: Bool = false) throws -> Date {
    let df = DateFormatter()
    df.calendar = gregorian
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    if isDateOnly(s) {
        df.dateFormat = "yyyy-MM-dd"
        guard let d = df.date(from: s) else { throw CoreError("bad date: \(s)") }
        guard let next = gregorian.date(byAdding: .day, value: 1, to: d) else {
            throw CoreError("bad date: \(s)")
        }
        return endOfDay ? next.addingTimeInterval(-1) : d
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    iso.timeZone = TimeZone.current
    if let d = iso.date(from: s) { return d }
    df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    guard let d = df.date(from: s) else {
        throw CoreError("bad date: \(s) (use yyyy-MM-dd or yyyy-MM-ddTHH:mm:ss)")
    }
    return d
}

public func parseDateOnly(_ s: String) throws -> Date {
    guard isDateOnly(s) else { throw CoreError("bad date: \(s) (use yyyy-MM-dd)") }
    return try parseDate(s)
}

// 終日イベントの end は「最終日を含む」日付で受ける。
public func allDayEndDate(start: Date, inclusiveEnd: Date?) throws -> Date {
    guard let inclusiveEnd else { return start }
    guard inclusiveEnd >= start else { throw CoreError("all-day end must be on or after start") }
    return inclusiveEnd
}

public func formatDateOnly(_ d: Date) -> String {
    let df = DateFormatter()
    df.calendar = gregorian
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    df.dateFormat = "yyyy-MM-dd"
    return df.string(from: d)
}

public func formatEventDate(_ d: Date, allDay: Bool) -> String {
    if allDay { return formatDateOnly(d) }
    return isoFormatter.string(from: d)
}

// 和暦ロケールだと Calendar.current が .japanese になり、
// dueDateComponents に入れると EventKit が例外を投げる。必ず gregorian を使う。
// hour/minute を入れないと EventKit 側で自動的に終日扱いになる。
public func parseDueComponents(_ s: String) throws -> DateComponents {
    let dateOnly = isDateOnly(s)
    let date = try parseDate(s)
    if dateOnly {
        return gregorian.dateComponents([.year, .month, .day], from: date)
    }
    var dc = gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    dc.timeZone = TimeZone.current
    return dc
}

public func date(fromComponents dc: DateComponents) -> Date? {
    var cal = gregorian
    if let tz = dc.timeZone { cal.timeZone = tz }
    return cal.date(from: dc)
}

public func formatDue(_ dc: DateComponents?) -> (String?, Bool?) {
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
