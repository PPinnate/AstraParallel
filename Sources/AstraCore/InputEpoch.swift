import Foundation

/// Cancels queued input on focus loss without waiting through paced key work.
/// Tokens contain no keystrokes or pointer coordinates.
public final class InputEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var pending = 0
    public init() {}
    public var current: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    public var queued: Int { lock.lock(); defer { lock.unlock() }; return pending }
    public func isCurrent(_ token: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return token == value }
    @discardableResult public func cancel() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1; pending = 0; return value
    }
    public func enqueue(limit: Int = 128) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard pending < limit else { return nil }
        pending += 1; return value
    }
    public func completed(_ token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if value == token { pending = max(0, pending - 1) }
    }
}
