import EventKit
import Foundation

let store = EKEventStore()

func fail(_ message: String) -> Never {
    let payload = ["error": message]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    exit(1)
}

func statusName(_ s: EKAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .fullAccess: return "fullAccess"
    case .writeOnly: return "writeOnly"
    case .authorized: return "authorized"
    @unknown default: return "unknown(\(s.rawValue))"
    }
}

private func awaitAccess(
    _ label: String,
    _ settingsName: String,
    _ entity: EKEntityType,
    _ request: (@escaping (Bool, Error?) -> Void) -> Void
) {
    let before = EKEventStore.authorizationStatus(for: entity)
    let timeout = Double(ProcessInfo.processInfo.environment["EVENTKIT_CLI_ACCESS_TIMEOUT"] ?? "") ?? 30
    let guidance = "System Settings > Privacy & Security > \(settingsName)"
    switch before {
    case .denied, .restricted:
        fail("\(label) access is \(statusName(before)). Allow access in \(guidance), then retry.")
    case .notDetermined:
        FileHandle.standardError.write(Data(
            "A macOS \(settingsName) permission dialog should be on screen. Grant access to continue (waiting up to \(Int(timeout))s).\n".utf8))
    default:
        break
    }

    let sem = DispatchSemaphore(value: 0)
    var granted = false
    var failure: Error?
    request { ok, err in
        granted = ok
        failure = err
        sem.signal()
    }
    // 初回は TCC ダイアログをユーザーがクリックするまで待つ。
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        fail("\(label) access request timed out after \(Int(timeout))s (status=\(statusName(before))). Check the screen for the permission dialog, or allow access in \(guidance).")
    }
    if !granted {
        let after = EKEventStore.authorizationStatus(for: entity)
        fail("\(label) access denied (status before=\(statusName(before)) after=\(statusName(after)), pid=\(getpid()), responsible=\(pathForPID(responsiblePID()))): \(failure?.localizedDescription ?? "no error"). Allow access in \(guidance).")
    }
}

func requestRemindersAccess() {
    awaitAccess("reminders", "Reminders", .reminder) { store.requestFullAccessToReminders(completion: $0) }
}

func requestCalendarAccess() {
    awaitAccess("calendar", "Calendars", .event) { store.requestFullAccessToEvents(completion: $0) }
}

func emit<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    let data = try! encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
