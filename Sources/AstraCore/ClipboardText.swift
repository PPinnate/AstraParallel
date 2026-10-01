import Foundation

/// Text-only sharing; data is bounded and never placed in diagnostic records.
public enum ClipboardText {
    public static let maximumBytes = 1_048_576
    public static func valid(_ text: String) -> Bool {
        !text.utf8.contains(0) && text.utf8.count <= maximumBytes
    }
    public static func decode(_ data: Data) -> String? {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8), valid(text) else { return nil }
        return text
    }
}
