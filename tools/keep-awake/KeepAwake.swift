import Foundation

@main struct KeepAwake {
    static func status() throws -> Bool {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g"]
        task.standardOutput = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let enabled = KeepAwakePolicy.sleepDisabled(text) else {
            throw NSError(domain: "KeepAwake", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Cannot read macOS SleepDisabled status. No settings were changed."])
        }
        return enabled
    }

    static func main() {
        do {
            guard let request = KeepAwakePolicy.request(Array(CommandLine.arguments.dropFirst())) else {
                throw NSError(domain: "KeepAwake", code: 2)
            }
            guard let enabled = request.enabled else {
                print(try status() ? "on" : "off")
                return
            }
            // Read first; do not change an unknown or already matching setting.
            if try status() == enabled { return }
            let sudo = Process()
            sudo.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            sudo.arguments = KeepAwakePolicy.sudoArguments(enabled: enabled)
            sudo.standardOutput = FileHandle.nullDevice
            sudo.standardError = FileHandle.nullDevice
            try sudo.run()
            sudo.waitUntilExit()
            if sudo.terminationStatus == 0 {
                guard try status() == enabled else {
                    throw NSError(domain: "KeepAwake", code: 4, userInfo: [NSLocalizedDescriptionKey:
                        "macOS did not confirm the requested sleep setting."])
                }
                return
            }
            guard request.prompt else {
                throw NSError(domain: "KeepAwake", code: 5, userInfo: [NSLocalizedDescriptionKey:
                    "Switching Keep Awake automatically needs WattNook's sleep-toggle rule. No password prompt was shown."])
            }
            // No rule (or revoked rule): use normal authorization, never sudo password input.
            let command = KeepAwakePolicy.command(enabled: enabled)
            let prompt = "WattNook: \(enabled ? "enable" : "disable") system-wide Keep Awake for closed-lid work."
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "do shell script \"\(command)\" with administrator privileges with prompt \"\(prompt)\""]
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                throw NSError(domain: "KeepAwake", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "Keep Awake was cancelled or macOS refused the change. Check its current status."])
            }
            guard try status() == enabled else {
                throw NSError(domain: "KeepAwake", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    "macOS did not confirm the requested sleep setting."])
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
