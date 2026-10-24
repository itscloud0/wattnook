import Foundation

enum KeepAwakePolicy {
    static func sudoArguments(enabled: Bool) -> [String] {
        ["-n", "/usr/bin/pmset", "-a", "disablesleep", enabled ? "1" : "0"]
    }
    static func sleepDisabled(_ output: String) -> Bool? {
        let rows = output.split(separator: "\n").map { $0.split(whereSeparator: { $0.isWhitespace }) }
            .filter { $0.first == "SleepDisabled" }
        guard rows.count == 1, rows[0].count == 2 else { return nil }
        switch rows[0][1] {
        case "0": return false
        case "1": return true
        default: return nil
        }
    }
    /// `--status`, or `--enable`/`--disable` with an optional `--no-prompt`:
    /// automatic switching may only use the installed sudo rule, never a
    /// password dialog. Anything else is rejected.
    static func request(_ args: [String]) -> (enabled: Bool?, prompt: Bool)? {
        switch args {
        case ["--status"]: return (nil, false)
        case ["--enable"], ["--disable"]: return (args[0] == "--enable", true)
        case ["--enable", "--no-prompt"], ["--disable", "--no-prompt"]: return (args[0] == "--enable", false)
        default: return nil
        }
    }
    static func command(enabled: Bool) -> String {
        "/usr/bin/pmset -a disablesleep \(enabled ? 1 : 0)"
    }
}
