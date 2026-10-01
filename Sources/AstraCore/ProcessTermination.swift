import Foundation
import Darwin

/// Only Process instances launched and retained by this session. No saved PID
/// or process-name matching is used to terminate somebody else's VM.
public enum ProcessTermination {
    public static func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while process.isRunning {
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            // Cleanup must retain ownership even if its caller is cancelled.
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
    /// Only for confirmed force stops, failed-start children, or a TPM after
    /// its engine has exited. A graceful Windows shutdown never calls this.
    public static func stop(_ process: Process, grace: TimeInterval = 2,
                            killWait: TimeInterval = 2) async -> Bool {
        if !process.isRunning { return true }
        process.terminate()
        if await waitForExit(process, timeout: grace) { return true }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        return await waitForExit(process, timeout: killWait)
    }
}
