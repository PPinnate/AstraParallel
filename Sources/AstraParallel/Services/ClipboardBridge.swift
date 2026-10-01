import AppKit
import AstraCore
import CocoaSpiceNoUsb

/// Opt-in, foreground-only text sharing. SPICE reads a locked cache instead of
/// synchronously calling the AppKit thread while it owns the SPICE context.
final class ClipboardBridge: NSObject, CSPasteboardDelegate {
    private let lock = NSLock()
    private var text: String?
    private var enabled = false
    private var generation: UInt64 = 0
    private var lastChange = -1
    private var timer: Timer?
    private weak var connection: CSConnection?

    func configure(connection: CSConnection?, allowed: Bool) {
        precondition(Thread.isMainThread)
        timer?.invalidate(); timer = nil
        let previous = self.connection
        lock.lock(); generation &+= 1; enabled = allowed; text = nil; lock.unlock()
        self.connection = connection
        if CSMain.shared.running {
            CSMain.shared.async {
                previous?.session.shareClipboard = false
                previous?.session.pasteboardDelegate = nil
                connection?.session.pasteboardDelegate = allowed ? self : nil
                connection?.session.shareClipboard = allowed
                if allowed {
                    DispatchQueue.main.async {
                        guard self.connection === connection else { return }
                        self.lastChange = -1; self.poll()
                    }
                }
            }
        } else {
            connection?.session.shareClipboard = false
            connection?.session.pasteboardDelegate = nil
        }
        guard allowed, connection != nil else { return }
        lastChange = -1
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        poll()
    }

    private func poll() {
        guard NSApp.isActive, let connection, CSMain.shared.running else { return }
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        let candidate = board.string(forType: .string).flatMap { ClipboardText.valid($0) ? $0 : nil }
        lock.lock(); let changed = text != candidate; text = candidate; let allowed = enabled; lock.unlock()
        guard allowed, changed else { return }
        CSMain.shared.async {
            guard connection.session.pasteboardDelegate === self, connection.session.shareClipboard else { return }
            NotificationCenter.default.post(name: .init("CSPasteboardChangedNotification"), object: self)
        }
    }

    func canReadItem(for type: CSPasteboardType) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && type.rawValue == 11 && text != nil
    }
    func data(for type: CSPasteboardType) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard enabled, type.rawValue == 11 else { return nil }
        return text?.data(using: .utf8)
    }
    func string() -> String? {
        lock.lock(); defer { lock.unlock() }; return enabled ? text : nil
    }
    func setData(_ data: Data, for type: CSPasteboardType) {
        guard type.rawValue == 11, let value = ClipboardText.decode(data) else { return }
        setString(value)
    }
    func setString(_ value: String) {
        guard ClipboardText.valid(value) else { return }
        lock.lock(); let token = generation; let allowed = enabled; lock.unlock()
        guard allowed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.isActive else { return }
            self.lock.lock()
            guard self.enabled, self.generation == token else { self.lock.unlock(); return }
            let same = self.text == value
            self.text = value
            self.lock.unlock()
            let board = NSPasteboard.general
            guard !same || board.changeCount != self.lastChange else { return }
            board.clearContents(); board.setString(value, forType: .string)
            self.lastChange = board.changeCount // suppress host→guest echo.
        }
    }
    func clearContents() {
        // Releasing guest ownership must not erase the user's Mac clipboard.
    }
    deinit { timer?.invalidate() }
}
