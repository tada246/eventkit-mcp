import Foundation

struct Args {
    let positional: [String]
    let flags: [String: String]
    let bools: Set<String>

    init(_ raw: [String]) {
        var positional: [String] = []
        var flags: [String: String] = [:]
        var bools: Set<String> = []
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < raw.count, !raw[i + 1].hasPrefix("--") {
                    flags[key] = raw[i + 1]
                    i += 2
                } else {
                    bools.insert(key)
                    i += 1
                }
            } else {
                positional.append(a)
                i += 1
            }
        }
        self.positional = positional
        self.flags = flags
        self.bools = bools
    }

    func value(_ key: String) -> String? { flags[key] }
    func has(_ key: String) -> Bool { bools.contains(key) || flags[key] != nil }
    func require(_ key: String) -> String {
        guard let v = flags[key] else { fail("missing required flag --\(key)") }
        return v
    }
}
