import Darwin
import Foundation

/// Only for short-lived helper processes created by LoopFwd, never agent PIDs.
/// Drain stdout while running so a full pipe cannot defeat the time budget.
enum BoundedProcess {
    struct Result {
        let output: String
        let status: Int32?
        let timedOut: Bool
        let exceededOutputLimit: Bool
        var succeeded: Bool { status == 0 && !timedOut && !exceededOutputLimit }
    }

    static func run(
        _ executable: String, _ arguments: [String],
        timeout: TimeInterval = 2, maximumBytes: Int = 1024 * 1024,
        removingEnvironmentKeys: [String] = []
    ) -> Result {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in removingEnvironmentKeys { environment.removeValue(forKey: key) }
        let bin = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        environment["PATH"] = bin + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        do { try process.run() } catch {
            return .init(output: "", status: nil, timedOut: false, exceededOutputLimit: false)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, timeout)
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        var timedOut = false
        var overflow = false
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                let room = max(0, maximumBytes - data.count)
                data.append(contentsOf: bytes.prefix(min(room, count)))
                overflow = count > room
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true }
            if overflow || timedOut { break }
            if !process.isRunning && count <= 0 { break }
            if count <= 0 { usleep(5000) }
        }
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.15
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(5000) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        return .init(
            output: String(decoding: data, as: UTF8.self), status: process.terminationStatus,
            timedOut: timedOut, exceededOutputLimit: overflow)
    }
}
