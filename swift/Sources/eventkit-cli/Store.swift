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
    _ entity: EKEntityType,
    _ request: (@escaping (Bool, Error?) -> Void) -> Void
) {
    let before = EKEventStore.authorizationStatus(for: entity)
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    var failure: Error?
    request { ok, err in
        granted = ok
        failure = err
        sem.signal()
    }
    // 初回は TCC ダイアログをユーザーがクリックするまで待つ。
    let timeout = Double(ProcessInfo.processInfo.environment["EVENTKIT_CLI_ACCESS_TIMEOUT"] ?? "") ?? 20
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        fail("\(label) access request timed out after \(Int(timeout))s (status=\(statusName(before))). 初回は権限ダイアログの操作が必要です。")
    }
    if !granted {
        let after = EKEventStore.authorizationStatus(for: entity)
        fail("\(label) access denied (status before=\(statusName(before)) after=\(statusName(after)), pid=\(getpid()), responsible=\(pathForPID(responsiblePID()))): \(failure?.localizedDescription ?? "no error")")
    }
}

func requestRemindersAccess() {
    awaitAccess("reminders", .reminder) { store.requestFullAccessToReminders(completion: $0) }
}

func requestCalendarAccess() {
    awaitAccess("calendar", .event) { store.requestFullAccessToEvents(completion: $0) }
}

func emit<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    let data = try! encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
