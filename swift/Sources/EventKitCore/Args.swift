import Foundation

public struct CoreError: Error, CustomStringConvertible, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

public struct Args {
    public let positional: [String]
    public let flags: [String: String]
    public let bools: Set<String>

    public init(_ raw: [String]) {
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

    public func value(_ key: String) -> String? { flags[key] }
    public func has(_ key: String) -> Bool { bools.contains(key) || flags[key] != nil }

    public func require(_ key: String) throws -> String {
        guard let v = flags[key] else { throw CoreError("missing required flag --\(key)") }
        return v
    }

    // --flag と --flag true|false の両方を受ける。未指定は nil。
    public func bool(_ key: String) throws -> Bool? {
        if let v = flags[key] {
            switch v.lowercased() {
            case "true": return true
            case "false": return false
            default: throw CoreError("--\(key) must be true or false, got: \(v)")
            }
        }
        return bools.contains(key) ? true : nil
    }

    public func clearFields() -> Set<String> {
        Set((flags["clear"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }
}

public func decodeJSON<T: Decodable>(_ type: T.Type, from json: String, label: String) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: Data(json.utf8))
    } catch {
        throw CoreError("bad \(label) JSON: \(error.localizedDescription)")
    }
}
