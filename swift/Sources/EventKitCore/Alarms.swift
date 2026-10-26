import EventKit
import Foundation

public struct AlarmSpec: Codable, Equatable {
    public var minutesBefore: Int?
    public var at: String?

    public init(minutesBefore: Int? = nil, at: String? = nil) {
        self.minutesBefore = minutesBefore
        self.at = at
    }
}

private enum AlarmKind {
    case relative(Int)
    case absolute(Date)
}

private func alarmKind(_ spec: AlarmSpec) throws -> AlarmKind {
    switch (spec.minutesBefore, spec.at) {
    case (let minutes?, nil):
        guard minutes >= 0 else {
            throw CoreError("alarm.minutesBefore must be >= 0, got: \(minutes)")
        }
        return .relative(minutes)
    case (nil, let at?):
        return .absolute(try parseDate(at))
    default:
        throw CoreError("alarm must have exactly one of minutesBefore or at")
    }
}

public func parseAlarms(_ json: String) throws -> [AlarmSpec] {
    try decodeJSON([AlarmSpec].self, from: json, label: "alarms")
}

public func makeEventAlarms(_ specs: [AlarmSpec]) throws -> [EKAlarm] {
    try specs.map { spec in
        switch try alarmKind(spec) {
        case .relative(let minutes):
            return EKAlarm(relativeOffset: -Double(minutes) * 60)
        case .absolute(let date):
            return EKAlarm(absoluteDate: date)
        }
    }
}

// リマインダーの相対アラームは基準が分かりにくいので、期限から絶対時刻に直して保存する。
public func makeReminderAlarms(_ specs: [AlarmSpec], due: Date?) throws -> [EKAlarm] {
    try specs.map { spec in
        switch try alarmKind(spec) {
        case .relative(let minutes):
            guard let due else {
                throw CoreError("relative alarm requires a due date on the reminder")
            }
            return EKAlarm(absoluteDate: due.addingTimeInterval(-Double(minutes) * 60))
        case .absolute(let date):
            return EKAlarm(absoluteDate: date)
        }
    }
}

public func alarmSpecs(from alarms: [EKAlarm]?) -> [AlarmSpec] {
    (alarms ?? []).map { alarm in
        if let date = alarm.absoluteDate {
            return AlarmSpec(at: isoFormatter.string(from: date))
        }
        return AlarmSpec(minutesBefore: Int((-alarm.relativeOffset / 60).rounded()))
    }
}

// リマインダーの出力は常に {at} 形式にする。相対アラームは期限から計算する。
public func reminderAlarmSpecs(from alarms: [EKAlarm]?, due: Date?) -> [AlarmSpec] {
    (alarms ?? []).map { alarm in
        if let date = alarm.absoluteDate {
            return AlarmSpec(at: isoFormatter.string(from: date))
        }
        if let due {
            return AlarmSpec(at: isoFormatter.string(from: due.addingTimeInterval(alarm.relativeOffset)))
        }
        return AlarmSpec(minutesBefore: Int((-alarm.relativeOffset / 60).rounded()))
    }
}
