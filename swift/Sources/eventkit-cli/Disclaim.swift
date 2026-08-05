import Darwin
import Foundation

// TCC はプロンプトの可否を「責任プロセス」の Info.plist で判定する。
// MCP ホスト (Claude Code / Claude Desktop) から起動されると責任プロセスが
// ホスト側になり、usage description が無いため EventKit が即 false を返す。
// 自分自身を disclaim 付きで再 exec して、責任プロセスを自分にする。
typealias SetDisclaimFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32

let disclaimEnvKey = "EVENTKIT_CLI_DISCLAIMED"

func reexecDisclaimed() {
    if ProcessInfo.processInfo.environment[disclaimEnvKey] != nil { return }
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return }
    let setDisclaim = unsafeBitCast(sym, to: SetDisclaimFn.self)

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC))
    _ = withUnsafeMutablePointer(to: &attr) { setDisclaim(UnsafeMutableRawPointer($0), 1) }

    let exePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
    var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
    argv.append(nil)
    var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
    envp.append(strdup("\(disclaimEnvKey)=1"))
    envp.append(nil)

    // POSIX_SPAWN_SETEXEC なので成功すればここには戻らない。
    _ = posix_spawn(nil, exePath, nil, &attr, &argv, &envp)
    posix_spawnattr_destroy(&attr)
}
