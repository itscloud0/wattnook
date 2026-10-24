import Foundation

@main struct Tests {
    static func main() throws {
        // Missing/malformed telemetry must never be interpreted as sleep enabled.
        assert(KeepAwakePolicy.sleepDisabled("System-wide power settings:\n SleepDisabled\t0\n") == false)
        assert(KeepAwakePolicy.sleepDisabled("System-wide power settings:\n SleepDisabled\t1\n") == true)
        assert(KeepAwakePolicy.sleepDisabled("SleepDisabled 10") == nil)
        assert(KeepAwakePolicy.sleepDisabled("SleepDisabled 1\nSleepDisabled 0") == nil)
        assert(KeepAwakePolicy.sleepDisabled("sleep 1\nlidwake 1") == nil)
        assert(KeepAwakePolicy.sleepDisabled("") == nil)
        // Commands are fixed; no caller-controlled command or sudoers modification.
        assert(KeepAwakePolicy.command(enabled: true) == "/usr/bin/pmset -a disablesleep 1")
        assert(KeepAwakePolicy.command(enabled: false) == "/usr/bin/pmset -a disablesleep 0")
        assert(KeepAwakePolicy.sudoArguments(enabled: true) == ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"])
        assert(KeepAwakePolicy.sudoArguments(enabled: false) == ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
        // Automatic switching never falls back to a password dialog.
        assert(KeepAwakePolicy.request(["--status"])! == (nil, false))
        assert(KeepAwakePolicy.request(["--enable"])! == (true, true))
        assert(KeepAwakePolicy.request(["--disable", "--no-prompt"])! == (false, false))
        assert(KeepAwakePolicy.request(["--no-prompt", "--enable"]) == nil)
        assert(KeepAwakePolicy.request(["--status", "--no-prompt"]) == nil)
        assert(KeepAwakePolicy.request([]) == nil)
        print("Keep Awake policy checks passed")
    }
}
