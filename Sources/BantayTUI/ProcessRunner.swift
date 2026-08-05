import Foundation

/// Non-blocking subprocess runner shared across the control plane (plan 016
/// 1c). Every call is async or fire-and-forget, so no main-actor path ever
/// blocks on `waitUntilExit`. Stdout/stderr are drained concurrently with
/// execution so >64KB of output cannot fill the pipe and deadlock.
nonisolated enum ProcessRunner {
    struct ProcessResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Clamp a requested timeout to the sane [0.5, 120] second window.
    /// Negative/zero values request the 0.5s floor; enormous values cap at
    /// 120s so a runaway process can never hold the runner open forever.
    static func clampedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        min(max(timeout, 0.5), 120.0)
    }

    /// Run to completion and return status + output. Output is drained
    /// concurrently on detached readers while the process executes. On
    /// timeout the process is terminated, reaped, and the partial output
    /// collected so far is returned. A launch failure (nonexistent
    /// executable) returns status -1 with empty output — never a hang.
    static func run(
        executableURL: URL,
        arguments: [String] = [],
        timeout: TimeInterval = 3.0,
        environment: [String: String]? = nil
    ) async -> ProcessResult {
        let clamped = clampedTimeout(timeout)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, stdout: "", stderr: "")
        }

        let stdoutRead = Task.detached(priority: .utility) {
            Self.readAll(stdout.fileHandleForReading)
        }
        let stderrRead = Task.detached(priority: .utility) {
            Self.readAll(stderr.fileHandleForReading)
        }

        _ = await waitForExit(process, timeout: clamped)
        // Reap the terminated child so it can never linger as a zombie.
        process.waitUntilExit()

        let out = await stdoutRead.value
        let err = await stderrRead.value
        return ProcessResult(
            status: process.terminationStatus,
            stdout: out,
            stderr: err)
    }

    /// Fire-and-forget: launch a child whose output nobody needs (approve /
    /// deny / keys). The termination handler holds the `Process` alive until
    /// the child exits, then clears itself so the process object is reaped.
    static func launch(executableURL: URL, arguments: [String] = []) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { p in
            p.terminationHandler = nil
        }
        do {
            try process.run()
        } catch {
            // Fire-and-forget: a failed spawn is a silent no-op.
        }
    }

    /// Read a pipe to EOF. Safe to run on a background task; the pipe write
    /// end closes when the child exits (the parent never opens the write
    /// side), so this returns promptly after termination.
    private static func readAll(_ handle: FileHandle) -> String {
        var data = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Wait for the child, terminating it after `timeout`. Returns true when
    /// the exit was caused by the timeout. Exactly-once resume is guaranteed
    /// by `Process.terminationHandler` firing once per exit.
    private static func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let state = ExitWatchState()
            process.terminationHandler = { _ in
                continuation.resume(returning: state.wasKilledByTimeout())
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if state.markKilledIfStillRunning(process) {
                    process.terminate()
                }
            }
        }
    }

    /// Lock-protected kill flag shared between the termination handler and
    /// the timeout task. Locking stays inside synchronous methods so the
    /// async context never touches the lock directly.
    private final class ExitWatchState: @unchecked Sendable {
        private let lock = NSLock()
        private var killedByTimeout = false

        /// Records the kill and returns true when the process is still
        /// running at the deadline; false when it already exited.
        func markKilledIfStillRunning(_ process: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard process.isRunning else { return false }
            killedByTimeout = true
            return true
        }

        func wasKilledByTimeout() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return killedByTimeout
        }
    }
}
