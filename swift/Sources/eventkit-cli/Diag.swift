import Darwin
import EventKit
import Foundation

typealias RespFn = @convention(c) (pid_t) -> pid_t

func responsiblePID() -> pid_t {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
        return -1
    }
    let fn = unsafeBitCast(sym, to: RespFn.self)
    return fn(getpid())
}

func pathForPID(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : "<unknown>"
}

func cmdDiag() {
    let info = Bundle.main.infoDictionary ?? [:]
    var out: [String: String] = [:]
    let rpid = responsiblePID()
    out["responsiblePID"] = String(rpid)
    out["responsiblePath"] = rpid > 0 ? pathForPID(rpid) : "<none>"
    out["parentPID"] = String(getppid())
    out["parentPath"] = pathForPID(getppid())
    out["bundlePath"] = Bundle.main.bundlePath
    out["bundleIdentifier"] = Bundle.main.bundleIdentifier ?? "<nil>"
    out["executablePath"] = Bundle.main.executablePath ?? "<nil>"
    out["infoDictionaryKeys"] = info.keys.sorted().joined(separator: ",")
    out["NSRemindersFullAccessUsageDescription"] = (info["NSRemindersFullAccessUsageDescription"] as? String) ?? "<MISSING>"
    out["NSCalendarsFullAccessUsageDescription"] = (info["NSCalendarsFullAccessUsageDescription"] as? String) ?? "<MISSING>"
    out["reminderStatus"] = statusName(EKEventStore.authorizationStatus(for: .reminder))
    out["eventStatus"] = statusName(EKEventStore.authorizationStatus(for: .event))
    out["pid"] = String(getpid())
    emit(out)
}
