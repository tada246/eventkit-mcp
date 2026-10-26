import EventKit
import EventKitCore
import Foundation
import Testing

private func parts(_ date: Date) -> DateComponents {
    gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
}

@Test func parsesDateOnly() throws {
    let date = try parseDate("2026-08-10")
    let c = parts(date)
    #expect(c.year == 2026)
    #expect(c.month == 8)
    #expect(c.day == 10)
    #expect(c.hour == 0)
    #expect(c.minute == 0)
    #expect(isDateOnly("2026-08-10"))
    #expect(!isDateOnly("2026-08-10T10:00:00"))
}

@Test func parsesLocalDateTime() throws {
    let date = try parseDate("2026-08-10T15:30:00")
    let c = parts(date)
    #expect(c.year == 2026)
    #expect(c.month == 8)
    #expect(c.day == 10)
    #expect(c.hour == 15)
    #expect(c.minute == 30)
}

@Test func parsesISOWithOffset() throws {
    let utc = try parseDate("2026-08-10T06:30:00Z")
    let jst = try parseDate("2026-08-10T15:30:00+09:00")
    #expect(abs(utc.timeIntervalSince1970 - 1_786_343_400) < 1)
    #expect(abs(jst.timeIntervalSince1970 - utc.timeIntervalSince1970) < 1)
}

@Test func rejectsBadDates() {
    #expect(throws: CoreError.self) { try parseDate("not-a-date") }
    #expect(throws: CoreError.self) { try parseDate("2026-13-01") }
    #expect(throws: CoreError.self) { try parseDateOnly("2026-08-10T10:00:00") }
}

@Test func allDayEndIsInclusive() throws {
    let start = try parseDateOnly("2026-08-22")
    let inclusiveEnd = try parseDateOnly("2026-08-23")
    let end = try allDayEndDate(start: start, inclusiveEnd: inclusiveEnd)
    #expect(formatDateOnly(end) == "2026-08-23")
    #expect(formatEventDate(start, allDay: true) == "2026-08-22")

    let oneDay = try allDayEndDate(start: start, inclusiveEnd: nil)
    #expect(formatDateOnly(oneDay) == "2026-08-22")
}

@Test func rejectsAllDayEndBeforeStart() {
    #expect(throws: CoreError.self) {
        try allDayEndDate(
            start: parseDateOnly("2026-08-23"),
            inclusiveEnd: parseDateOnly("2026-08-22"))
    }
}

@Test func buildsBiweeklyRule() throws {
    let start = try parseDateOnly("2026-08-10")  // Monday
    let rule = try makeRecurrenceRule(
        RecurrenceSpec(frequency: "weekly", interval: 2), start: start)
    #expect(rule.frequency == .weekly)
    #expect(rule.interval == 2)
    #expect(rule.daysOfTheWeek?.count == 1)
    #expect(rule.daysOfTheWeek?.first?.dayOfTheWeek == .monday)
}

@Test func buildsMultipleWeekdaysRule() throws {
    let start = try parseDateOnly("2026-08-10")  // Monday
    let rule = try makeRecurrenceRule(
        RecurrenceSpec(frequency: "weekly", daysOfWeek: ["mon", "thu"]), start: start)
    let days = rule.daysOfTheWeek?.map(\.dayOfTheWeek) ?? []
    #expect(days.count == 2)
    #expect(days.contains(.monday))
    #expect(days.contains(.thursday))
}

@Test func buildsUntilRule() throws {
    let start = try parseDateOnly("2026-08-10")
    let rule = try makeRecurrenceRule(
        RecurrenceSpec(frequency: "weekly", until: "2027-01-20"), start: start)
    let end = try #require(rule.recurrenceEnd)
    #expect(end.occurrenceCount == 0)
    let c = parts(try #require(end.endDate))
    #expect(c.year == 2027)
    #expect(c.month == 1)
    #expect(c.day == 20)
    #expect(c.hour == 23)
    #expect(c.minute == 59)
    #expect(c.second == 59)
}

@Test func buildsCountRule() throws {
    let start = try parseDateOnly("2026-08-10")
    let rule = try makeRecurrenceRule(
        RecurrenceSpec(frequency: "daily", count: 14), start: start)
    let end = try #require(rule.recurrenceEnd)
    #expect(end.occurrenceCount == 14)
    #expect(end.endDate == nil)
}

@Test func rejectsInvalidRecurrenceCombinations() throws {
    let start = try parseDateOnly("2026-08-10")  // Monday
    #expect(throws: CoreError.self) {
        try makeRecurrenceRule(
            RecurrenceSpec(frequency: "weekly", until: "2027-01-20", count: 14), start: start)
    }
    #expect(throws: CoreError.self) {
        try makeRecurrenceRule(RecurrenceSpec(frequency: "weekly", interval: 0), start: start)
    }
    #expect(throws: CoreError.self) {
        try makeRecurrenceRule(RecurrenceSpec(frequency: "hourly"), start: start)
    }
    #expect(throws: CoreError.self) {
        try makeRecurrenceRule(
            RecurrenceSpec(frequency: "daily", daysOfWeek: ["mon"]), start: start)
    }
    #expect(throws: CoreError.self) {
        try makeRecurrenceRule(
            RecurrenceSpec(frequency: "weekly", daysOfWeek: ["mon", "nope"]), start: start)
    }
    #expect(throws: CoreError.self) {
        try makeRecurrenceRule(
            RecurrenceSpec(frequency: "weekly", daysOfWeek: []), start: start)
    }
}

@Test func rejectsWeeklyDaysWithoutStartWeekday() throws {
    let start = try parseDateOnly("2026-08-11")  // Tuesday
    #expect(throws: CoreError.self) {
        try makeRecurrenceRule(
            RecurrenceSpec(frequency: "weekly", daysOfWeek: ["mon", "thu"]), start: start)
    }
}

@Test func recurrenceRoundTripToOutputJSON() throws {
    let start = try parseDateOnly("2026-08-10")  // Monday
    let spec = RecurrenceSpec(
        frequency: "weekly",
        interval: 2,
        daysOfWeek: ["mon", "thu"],
        until: "2027-01-20")
    let rule = try makeRecurrenceRule(spec, start: start)
    let output = recurrenceSpec(from: rule)
    #expect(output == spec)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = String(decoding: try encoder.encode(output), as: UTF8.self)
    #expect(json == #"{"daysOfWeek":["mon","thu"],"frequency":"weekly","interval":2,"until":"2027-01-20"}"#)
}

@Test func parsesAlarmSpecs() throws {
    let specs = try parseAlarms(
        #"[{"minutesBefore":30},{"at":"2026-11-01T08:00:00"}]"#)
    #expect(specs.count == 2)
    #expect(specs[0] == AlarmSpec(minutesBefore: 30))
    #expect(specs[1] == AlarmSpec(at: "2026-11-01T08:00:00"))
}

@Test func rejectsInvalidAlarms() throws {
    #expect(throws: CoreError.self) {
        try makeEventAlarms([AlarmSpec(minutesBefore: 30, at: "2026-11-01T08:00:00")])
    }
    #expect(throws: CoreError.self) {
        try makeEventAlarms([AlarmSpec()])
    }
    #expect(throws: CoreError.self) {
        try makeEventAlarms([AlarmSpec(minutesBefore: -1)])
    }
    #expect(throws: CoreError.self) {
        try makeEventAlarms([AlarmSpec(at: "bad")])
    }
}

@Test func makesEventAlarms() throws {
    let relative = try makeEventAlarms([AlarmSpec(minutesBefore: 30)])
    #expect(relative[0].absoluteDate == nil)
    #expect(relative[0].relativeOffset == -1800)

    let at = try parseDate("2026-11-01T08:00:00")
    let absolute = try makeEventAlarms([AlarmSpec(at: "2026-11-01T08:00:00")])
    #expect(absolute[0].absoluteDate == at)
}

@Test func makesReminderAlarmsFromDue() throws {
    let due = try parseDate("2026-11-01T09:00:00")
    let alarms = try makeReminderAlarms([AlarmSpec(minutesBefore: 30)], due: due)
    #expect(alarms[0].absoluteDate == due.addingTimeInterval(-1800))

    let absolute = try makeReminderAlarms(
        [AlarmSpec(at: "2026-11-01T08:00:00")], due: nil)
    #expect(absolute[0].absoluteDate == (try parseDate("2026-11-01T08:00:00")))
}

@Test func rejectsRelativeReminderAlarmWithoutDue() {
    #expect(throws: CoreError.self) {
        try makeReminderAlarms([AlarmSpec(minutesBefore: 30)], due: nil)
    }
}

@Test func formatsReminderAlarmsAsAbsolute() throws {
    let due = try parseDate("2026-11-01T09:00:00")
    let alarms = try makeReminderAlarms([AlarmSpec(minutesBefore: 30)], due: due)
    let specs = reminderAlarmSpecs(from: alarms, due: due)
    #expect(specs.count == 1)
    #expect(specs[0].minutesBefore == nil)
    #expect(specs[0].at == isoFormatter.string(from: due.addingTimeInterval(-1800)))
}

@Test func formatsEventAlarms() throws {
    let relative = try makeEventAlarms([AlarmSpec(minutesBefore: 30)])
    let specs = alarmSpecs(from: relative)
    #expect(specs == [AlarmSpec(minutesBefore: 30)])
}

@Test func parsesArgs() {
    let args = Args(["foo", "--title", "bar", "--all", "--clear", "due,notes"])
    #expect(args.positional == ["foo"])
    #expect(args.value("title") == "bar")
    #expect(args.has("all"))
    #expect(args.clearFields() == ["due", "notes"])
}

@Test func parsesBooleanFlags() throws {
    let absent = try Args([]).bool("all-day")
    #expect(absent == nil)
    let present = try Args(["--all-day"]).bool("all-day")
    #expect(present == true)
    let explicit = try Args(["--all-day", "false"]).bool("all-day")
    #expect(explicit == false)
    #expect(throws: CoreError.self) {
        try Args(["--all-day", "maybe"]).bool("all-day")
    }
}

@Test func requireThrowsWhenMissing() {
    #expect(throws: CoreError.self) { try Args([]).require("id") }
}
