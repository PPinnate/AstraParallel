import Foundation

public enum PCModifierKeys {
    /// Device-specific side bits from Apple's IOLLEvent.h. Preserve right Alt
    /// (AltGr) and independent left/right Shift, Control and Windows keys.
    /// Synthesized events without side bits retain the left-side fallback.
    public static func scanCodes(flags: UInt) -> Set<Int32> {
        let families: [(UInt, UInt, UInt, Int32, Int32)] = [
            (1 << 17, 0x2, 0x4, 0x2a, 0x36),
            (1 << 18, 0x1, 0x2000, 0x1d, 0x11d),
            (1 << 19, 0x20, 0x40, 0x38, 0x138),
            (1 << 20, 0x8, 0x10, 0x15b, 0x15c)
        ]
        var result = Set<Int32>()
        for (aggregate, left, right, leftCode, rightCode) in families where flags & aggregate != 0 {
            if flags & right != 0 { result.insert(rightCode) }
            if flags & left != 0 || flags & (left | right) == 0 { result.insert(leftCode) }
        }
        return result
    }
}
