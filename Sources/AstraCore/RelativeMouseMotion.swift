import CoreGraphics

/// SPICE transports integer motion. Retain slow trackpad movement between
/// packets, and discard its remainder only on a capture/session transition.
public struct RelativeMouseMotion {
    // A fixed half-pixel origin rounds cumulative travel to the nearest pixel.
    // Keeping the residual in [0, 1) makes reversals independent of batching.
    private var remainder = CGPoint(x: 0.5, y: 0.5)

    public init() {}

    public mutating func consume(_ delta: CGPoint) -> CGPoint {
        guard delta.x.isFinite, delta.y.isFinite else { return .zero }
        let total = CGPoint(x: remainder.x + delta.x, y: remainder.y + delta.y)
        // CSInput ultimately converts each axis to a signed 32-bit integer.
        guard abs(total.x) <= CGFloat(Int32.max), abs(total.y) <= CGFloat(Int32.max) else { return .zero }
        let whole = CGPoint(x: total.x.rounded(.down), y: total.y.rounded(.down))
        remainder = CGPoint(x: total.x - whole.x, y: total.y - whole.y)
        return whole
    }

    public mutating func reset() { remainder = CGPoint(x: 0.5, y: 0.5) }
}
