import EventKit
import Foundation

public struct RecurrenceSpec: Codable, Equatable {
    public var frequency: String
    public var interval: Int?
    public var daysOfWeek: [String]?
    public var until: String?
    public var count: Int?

    public init(
        frequency: String,
        interval: Int? = nil,
        daysOfWeek: [String]? = nil,
        until: String? = nil,
        count: Int? = nil
    ) {
        self.frequency = frequency
        self.interval = interval
        self.daysOfWeek = daysOfWeek
        self.until = until
        self.count = count
    }
}

private let weekdayNames: [String: EKWeekday] = [
    "sun": .sunday,
    "mon": .monday,
    "tue": .tuesday,
    "wed": .wednesday,
    "thu": .thursday,
    "fri": .friday,
    "sat": .saturday,
]

private func frequency(from name: String) -> EKRecurrenceFrequency? {
    switch name.lowercased() {
    case "daily": return .daily
    case "weekly": return .weekly
    case "monthly": return .monthly
    case "yearly": return .yearly
    default: return nil
    }
}

private func frequencyName(_ frequency: EKRecurrenceFrequency) -> String {
    switch frequency {
    case .daily: return "daily"
    case .weekly: return "weekly"
    case .monthly: return "monthly"
    case .yearly: return "yearly"
    @unknown default: return "daily"
    }
}

public func weekdayName(for date: Date) -> String {
    switch gregorian.component(.weekday, from: date) {
    case 1: return "sun"
    case 2: return "mon"
    case 3: return "tue"
    case 4: return "wed"
    case 5: return "thu"
    case 6: return "fri"
    default: return "sat"
    }
}

private func weekdayName(_ weekday: EKWeekday) -> String {
    switch weekday {
    case .sunday: return "sun"
    case .monday: return "mon"
    case .tuesday: return "tue"
    case .wednesday: return "wed"
    case .thursday: return "thu"
    case .friday: return "fri"
    case .saturday: return "sat"
    @unknown default: return "sun"
    }
}

public func parseRecurrence(_ json: String) throws -> RecurrenceSpec {
    try decodeJSON(RecurrenceSpec.self, from: json, label: "recurrence")
}

public func makeRecurrenceRule(_ spec: RecurrenceSpec, start: Date) throws -> EKRecurrenceRule {
    guard let frequency = frequency(from: spec.frequency) else {
        throw CoreError("recurrence.frequency must be daily, weekly, monthly or yearly, got: \(spec.frequency)")
    }
    let interval = spec.interval ?? 1
    guard interval >= 1 else {
        throw CoreError("recurrence.interval must be >= 1, got: \(interval)")
    }
    if spec.until != nil && spec.count != nil {
        throw CoreError("recurrence.until and recurrence.count are mutually exclusive")
    }
    if let count = spec.count, count < 1 {
        throw CoreError("recurrence.count must be >= 1, got: \(count)")
    }
    if frequency != .weekly && spec.daysOfWeek != nil {
        throw CoreError("recurrence.daysOfWeek is only valid with frequency weekly")
    }

    var days: [EKRecurrenceDayOfWeek]?
    if frequency == .weekly {
        let names = spec.daysOfWeek ?? [weekdayName(for: start)]
        guard !names.isEmpty else {
            throw CoreError("recurrence.daysOfWeek must not be empty")
        }
        var result: [EKRecurrenceDayOfWeek] = []
        for name in names {
            guard let weekday = weekdayNames[name.lowercased()] else {
                throw CoreError("bad recurrence.daysOfWeek entry: \(name) (use sun, mon, tue, wed, thu, fri, sat)")
            }
            result.append(EKRecurrenceDayOfWeek(dayOfTheWeek: weekday, weekNumber: 0))
        }
        let startWeekday = gregorian.component(.weekday, from: start)
        guard result.contains(where: { $0.dayOfTheWeek.rawValue == startWeekday }) else {
            throw CoreError("recurrence.daysOfWeek must include the start weekday (\(weekdayName(for: start)))")
        }
        days = result
    }

    var end: EKRecurrenceEnd?
    if let until = spec.until {
        end = EKRecurrenceEnd(end: try parseDate(until, endOfDay: isDateOnly(until)))
    } else if let count = spec.count {
        end = EKRecurrenceEnd(occurrenceCount: count)
    }

    return EKRecurrenceRule(
        recurrenceWith: frequency,
        interval: interval,
        daysOfTheWeek: days,
        daysOfTheMonth: nil,
        monthsOfTheYear: nil,
        weeksOfTheYear: nil,
        daysOfTheYear: nil,
        setPositions: nil,
        end: end
    )
}

public func recurrenceSpec(from rule: EKRecurrenceRule) -> RecurrenceSpec {
    var spec = RecurrenceSpec(
        frequency: frequencyName(rule.frequency),
        interval: rule.interval == 1 ? nil : rule.interval
    )
    if let days = rule.daysOfTheWeek, !days.isEmpty {
        spec.daysOfWeek = days.map { weekdayName($0.dayOfTheWeek) }
    }
    if let end = rule.recurrenceEnd {
        if end.occurrenceCount > 0 {
            spec.count = end.occurrenceCount
        } else if let date = end.endDate {
            spec.until = formatDateOnly(date)
        }
    }
    return spec
}
