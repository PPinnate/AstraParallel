import SwiftUI
import MetalKit
import CocoaSpiceNoUsb
import CocoaSpiceRenderer
import AstraCore
import OSLog

struct GuestDisplayView: NSViewRepresentable {
    @ObservedObject var session: VirtualMachineSession
    func makeNSView(context: Context) -> GuestMetalView {
        let view = GuestMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.session = session
        return view
    }
    func updateNSView(_ view: GuestMetalView, context: Context) { view.update(session: session) }
    static func dismantleNSView(_ view: GuestMetalView, coordinator: ()) { view.disconnect() }
}

final class GuestMetalView: MTKView {
    weak var session: VirtualMachineSession?
    private var renderer: CSMetalRenderer!
    private var source: CSDisplay?
    private var mouseInput: CSInput?
    private var needsInitialKeyboardFocus = false
    private var tracking: NSTrackingArea?
    private var resizeWork: DispatchWorkItem?
    private var hiddenCursor = false
    private var captured = false
    private var capturePending = false
    private var captureGeneration: UInt64 = 0
    private var capturedEventMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private var relativeModeAcknowledged = false
    private var buttons = CSInputButton(rawValue: 0)
    private var heldModifiers: Set<Int32> = []
    private var lastRequestedSize = CGSize.zero
    private var focusObserver: NSObjectProtocol?
    private var keyUpMonitor: Any?
    private var pressedKeys: Set<Int32> = []
    private var cursorOwnerObservation: NSKeyValueObservation?
    private var cursorObservations: [NSKeyValueObservation] = []
    private weak var observedCursor: CSCursor?
    private var nativeCursor: NSCursor?
    private var nativeCursorActive = false
    private var metricsTimer: Timer?
    private let evidenceWriter = DispatchQueue(label: "local.astra.viewer-evidence", qos: .utility)
    private let logger = Logger(subsystem: "local.astra.parallel", category: "Input")

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        preferredFramesPerSecond = 60
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
        renderer = CSMetalRenderer(metalKitView: self)
        renderer.changeUpscaler(.nearest, downscaler: .linear)
        delegate = renderer
        focusObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            self?.releaseInput()
        }
        // Mouse events are normally routed by pointer location, not first
        // responder. Capture can begin from the toolbar; keep its motion and
        // buttons routed to this display while the host pointer is detached.
        capturedEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel, .flagsChanged
        ]) { [weak self] event in
            guard let self, self.captured || self.capturePending,
                  let window = self.window, window.isKeyWindow, NSApp.isActive else { return event }
            if event.type == .flagsChanged {
                if event.modifierFlags.contains([.control, .option]) {
                    self.releaseInput()
                    return nil
                }
                return event
            }
            guard event.window === window else { return event }
            if self.capturePending { return nil }
            switch event.type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: self.move(event)
            case .leftMouseDown: self.button(event, mask: 1, pressed: true)
            case .leftMouseUp: self.button(event, mask: 1, pressed: false)
            case .rightMouseDown: self.button(event, mask: 4, pressed: true)
            case .rightMouseUp: self.button(event, mask: 4, pressed: false)
            case .otherMouseDown, .otherMouseUp:
                if let mask = self.otherButtonMask(event) {
                    self.button(event, mask: mask, pressed: event.type == .otherMouseDown)
                }
            case .scrollWheel: self.scrollWheel(with: event)
            default: return event
            }
            return nil
        }
        setAccessibilityLabel("Windows guest display")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, event.window === self.window,
                  let code = PCKeyboard.scanCode(for: event.keyCode), self.pressedKeys.contains(code) else { return event }
            // SwiftUI's responder bridge can consume key-up before it reaches
            // an embedded NSView. Handle releases for keys this guest received.
            self.keyUp(with: event)
            return nil
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.recordTimings() }
        metricsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func accessibilityPerformPress() -> Bool {
        guard mouseInput != nil else { return false }
        return window?.makeFirstResponder(self) ?? false
    }
    deinit {
        metricsTimer?.invalidate()
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
        if let capturedEventMonitor { NSEvent.removeMonitor(capturedEventMonitor) }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        // dismantle/disconnect is the normal path; preserve the host cursor
        // even if AppKit destroys this view without that callback.
        if captured { CGAssociateMouseAndMouseCursorPosition(1) }
        if hiddenCursor { NSCursor.unhide() }
    }

    func update(session: VirtualMachineSession) {
        self.session = session
        session.inputDispatcher.onOverflow = { [weak self] in
            self?.releaseInput()
            self?.session?.captureError = "Input backlog cleared. Click the guest or capture the mouse again."
        }
        if isPaused != session.lowLatencyDisplay {
            isPaused = session.lowLatencyDisplay
            renderer.resetTimingStatistics()
        }
        if mouseInput !== session.input {
            releaseInput()
            mouseInput = session.input
            needsInitialKeyboardFocus = session.input != nil
        }
        if source !== session.display {
            source?.removeRenderer(renderer)
            source = session.display
            source?.addRenderer(renderer)
            cursorOwnerObservation = source?.observe(\.hostCursor, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.observeCursor() }
            }
        }
        if session.display == nil && (captured || capturePending) { releaseInput() }
        // A newly started VM must receive the installer's early "press any
        // key" prompt without requiring a separate click into the display.
        if needsInitialKeyboardFocus, mouseInput != nil, source != nil,
           NSApp.isActive, let window, window.isKeyWindow,
           window.makeFirstResponder(self) {
            needsInitialKeyboardFocus = false
        }
        if session.captureMouse {
            if !captured && !capturePending { beginCapture() }
        } else if captured || capturePending {
            releaseInput()
        }
        updateViewport()
        updateNativeCursor()
        scheduleResolution()
    }
    func disconnect() {
        releaseInput()
        resizeWork?.cancel()
        source?.removeRenderer(renderer); source = nil
        delegate = nil
        mouseInput = nil
        metricsTimer?.invalidate()
        cursorOwnerObservation = nil; cursorObservations.removeAll()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { releaseInput() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        if let window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.releaseInput()
                })
            }
        }
        window?.acceptsMouseMovedEvents = true
        preferredFramesPerSecond = window?.screen?.maximumFramesPerSecond ?? 60
    }
    override func layout() {
        super.layout()
        updateViewport()
        updateNativeCursor()
        scheduleResolution()
    }
    private func scheduleResolution() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let session = self.session, session.resolution == "Automatic", session.guestAgentConnected else { return }
            let width = floor(self.drawableSize.width / 2) * 2
            let height = floor(self.drawableSize.height / 2) * 2
            if width >= 640, height >= 480, width <= 7680, height <= 4320 {
                let size = CGSize(width: width, height: height)
                if size != self.lastRequestedSize {
                    self.lastRequestedSize = size
                    session.requestResolution(size)
                }
            }
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    private func updateViewport() {
        guard let source, source.displaySize.width > 0, source.displaySize.height > 0 else { return }
        let size = source.displaySize
        renderer.viewportScale = min(drawableSize.width / size.width, drawableSize.height / size.height)
        renderer.viewportOrigin = .zero
        guard let session else { return }
        let record: [String: Any] = ["observed_at": ISO8601DateFormatter().string(from: Date()),
            "guest_width": Int(size.width), "guest_height": Int(size.height),
            "drawable_width": Int(drawableSize.width), "drawable_height": Int(drawableSize.height),
            "backing_scale": window?.backingScaleFactor ?? 1, "presentation_scale": renderer.viewportScale,
            "requested_resolution": session.resolution, "render_device": device?.name ?? "Unavailable",
            "guest_fps": NSNull(), "input_to_photon_ms": NSNull()]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            let file = session.evidenceDirectory.appendingPathComponent("viewer.json")
            evidenceWriter.async { try? data.write(to: file, options: .atomic) }
        }
    }
    private func observeCursor() {
        guard observedCursor !== source?.hostCursor else { updateNativeCursor(); return }
        cursorObservations.removeAll()
        observedCursor = source?.hostCursor
        if let cursor = observedCursor {
            cursorObservations = [
                cursor.observe(\.imageData, options: [.initial, .new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.updateNativeCursor() }
                },
                cursor.observe(\.cursorHidden, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.updateNativeCursor() }
                }
            ]
        }
        updateNativeCursor()
    }
    private func updateNativeCursor() {
        guard let source else { return }
        let cursor = source.hostCursor
        let available = (cursor?.imageData?.count ?? 0) > 0
        if session?.nativeCursorAvailable != available { session?.nativeCursorAvailable = available }
        var next: NSCursor?
        if session?.useNativeCursor == true, !captured,
           let cursor, let data = cursor.imageData,
           source.displaySize.width > 0, source.displaySize.height > 0 {
            let width = Int(cursor.imageSize.width), height = Int(cursor.imageSize.height)
            if width > 0, height > 0, width <= 512, height <= 512, data.count == width * height * 4,
               let provider = CGDataProvider(data: data as CFData),
               let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                let scale = min(bounds.width / source.displaySize.width, bounds.height / source.displaySize.height)
                if scale > 0 {
                    let size = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
                    next = NSCursor(image: NSImage(cgImage: image, size: size),
                                    hotSpot: CGPoint(x: cursor.imageHotspot.x * scale, y: cursor.imageHotspot.y * scale))
                }
            }
        }
        let active = next != nil
        nativeCursor = next
        if nativeCursorActive != active {
            nativeCursorActive = active
            logger.info("Native desktop cursor active: \(active, privacy: .public)")
        }
        if let cursor, cursor.isInhibited != active, CSMain.shared.running {
            CSMain.shared.async { cursor.isInhibited = active }
        }
        window?.invalidateCursorRects(for: self)
        if let window, window.isKeyWindow, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            applyCursor()
        }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if let nativeCursor, !captured { addCursorRect(bounds, cursor: nativeCursor) }
    }
    private func applyCursor() {
        if captured || (nativeCursorActive && source?.hostCursor?.cursorHidden == true) {
            hideCursor()
        } else if let nativeCursor, nativeCursorActive {
            showCursor(); nativeCursor.set()
        } else if source != nil { hideCursor() }
    }
    private func recordTimings() {
        guard let session, session.isRunning else { return }
        let record: [String: Any] = ["observed_at": ISO8601DateFormatter().string(from: Date()),
            "guest_width": Int(session.guestSize.width), "guest_height": Int(session.guestSize.height),
            "native_cursor_active": nativeCursorActive, "capture_mouse": captured,
            "capture_pending": capturePending, "relative_mode_acknowledged": relativeModeAcknowledged,
            "presentation_mode": isPaused ? "direct" : "timer",
            "native_cursor_requested": session.useNativeCursor,
            "cursor_channel_present": source?.hostCursor != nil,
            "cursor_image_bytes": source?.hostCursor?.imageData?.count ?? 0,
            "cursor_image_width": source?.hostCursor?.imageSize.width ?? 0,
            "cursor_image_height": source?.hostCursor?.imageSize.height ?? 0,
            "input": session.inputDispatcher.timings.snapshot(), "presentation": renderer.timingStatistics,
            "audio": session.playbackStatistics,
            "input_to_photon_ms": NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) else { return }
        let file = session.evidenceDirectory.appendingPathComponent("timing.json")
        evidenceWriter.async { try? data.write(to: file, options: .atomic) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(tracking!)
    }
    private func hideCursor() { if !hiddenCursor { NSCursor.hide(); hiddenCursor = true } }
    private func showCursor() { if hiddenCursor { NSCursor.unhide(); hiddenCursor = false } }
    override func mouseEntered(with event: NSEvent) { applyCursor() }
    override func mouseExited(with event: NSEvent) {
        if !captured && !capturePending { releaseInput(); NSCursor.arrow.set() }
    }
    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func rightMouseDragged(with event: NSEvent) { move(event) }
    override func otherMouseDragged(with event: NSEvent) { move(event) }
    private func move(_ event: NSEvent) {
        guard !capturePending, let source, let input = mouseInput, let session else { return }
        let age = ProcessInfo.processInfo.systemUptime - event.timestamp
        if age >= 0, age < 5 { session.inputDispatcher.timings.add("appkit_event_age", milliseconds: age * 1000) }
        let mask = buttons
        if captured {
            let delta = CGPoint(x: event.deltaX, y: event.deltaY)
            session.inputDispatcher.pointer(input, point: delta, buttons: mask, relative: true)
        } else {
            let point = convert(event.locationInWindow, from: nil)
            guard let mapped = DisplayGeometry.guestPoint(viewPoint: point, viewSize: bounds.size, guestSize: source.displaySize) else { return }
            session.inputDispatcher.pointer(input, point: mapped, buttons: mask, relative: false)
            // This driver draws its software cursor inside guest frames. An
            // empty SPICE cursor must not re-present the old 4K frame on every
            // host mouse event while Windows is producing the new position.
            if !nativeCursorActive, let cursor = source.hostCursor,
               cursor.cursorSize.width > 0, cursor.cursorSize.height > 0 {
                cursor.move(to: mapped)
            }
        }
    }
    private func button(_ event: NSEvent, mask: UInt, pressed: Bool) {
        guard !capturePending, mouseInput != nil else { return }
        let key = CSInputButton(rawValue: mask)
        if !pressed && !buttons.contains(key) { return }
        window?.makeFirstResponder(self)
        move(event)
        if pressed { buttons.insert(key) } else { buttons.remove(key) }
        let mask = buttons
        let point = convert(event.locationInWindow, from: nil)
        let mapped = captured ? nil : source.flatMap { DisplayGeometry.guestPoint(viewPoint: point, viewSize: bounds.size, guestSize: $0.displaySize) }
        if let input = mouseInput { session?.inputDispatcher.mouseButton(input, button: key, buttons: mask, pressed: pressed, absolutePoint: mapped) }
    }
    override func mouseDown(with event: NSEvent) { button(event, mask: 1, pressed: true) }
    override func mouseUp(with event: NSEvent) { button(event, mask: 1, pressed: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, mask: 4, pressed: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, mask: 4, pressed: false) }
    private func otherButtonMask(_ event: NSEvent) -> UInt? {
        switch event.buttonNumber { case 2: return 2; case 3: return 32; case 4: return 64; default: return nil }
    }
    override func otherMouseDown(with event: NSEvent) { if let mask = otherButtonMask(event) { button(event, mask: mask, pressed: true) } }
    override func otherMouseUp(with event: NSEvent) { if let mask = otherButtonMask(event) { button(event, mask: mask, pressed: false) } }
    override func scrollWheel(with event: NSEvent) {
        guard !capturePending, let input = mouseInput else { return }
        session?.inputDispatcher.scroll(input, buttons: buttons, delta: event.scrollingDeltaY)
    }
    override func keyDown(with event: NSEvent) {
        if handleHostShortcut(event) { return }
        if captured || capturePending, event.modifierFlags.contains([.control, .option]) { releaseInput(); return }
        if event.isARepeat { return }
        syncModifiers(event.modifierFlags)
        if let code = PCKeyboard.scanCode(for: event.keyCode) {
            pressedKeys.insert(code)
            sendKey(code, pressed: true)
        }
    }
    override func keyUp(with event: NSEvent) {
        guard let code = PCKeyboard.scanCode(for: event.keyCode), pressedKeys.remove(code) != nil else { return }
        // A physical key must still be released if Command was pressed later.
        syncModifiers(event.modifierFlags)
        sendKey(code, pressed: false)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Leave the native Capture Mouse for Games menu shortcut to AppKit.
        if event.modifierFlags.contains([.command, .shift]),
           event.charactersIgnoringModifiers?.lowercased() == "m" { return false }
        guard window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.command), mouseInput != nil else {
            return super.performKeyEquivalent(with: event)
        }
        if handleHostShortcut(event) { return true }
        guard let code = PCKeyboard.scanCode(for: event.keyCode) else { return false }
        // AppKit may omit keyUp for Command shortcuts. Send a balanced chord.
        if !event.isARepeat {
            syncModifiers(event.modifierFlags)
            sendKey(code, pressed: true)
            sendKey(code, pressed: false)
            syncModifiers([])
        }
        return true
    }
    override func flagsChanged(with event: NSEvent) {
        if captured || capturePending, event.modifierFlags.contains([.control, .option]) { releaseInput(); return }
        syncModifiers(event.modifierFlags)
    }
    private func syncModifiers(_ flags: NSEvent.ModifierFlags) {
        let desired = PCModifierKeys.scanCodes(flags: flags.rawValue)
        for code in heldModifiers.subtracting(desired) { sendKey(code, pressed: false) }
        for code in desired.subtracting(heldModifiers) { sendKey(code, pressed: true) }
        heldModifiers = desired
        send { input in
            var locks = input.keyLock
            let caps = CSInputKeyLock(rawValue: 4)
            if flags.contains(.capsLock) { locks.insert(caps) } else { locks.remove(caps) }
            if locks != input.keyLock { input.keyLock = locks }
        }
    }
    override func resignFirstResponder() -> Bool { releaseInput(); return super.resignFirstResponder() }
    private func beginCapture() {
        session?.captureError = nil
        guard source != nil, let input = mouseInput, let session, let window,
              NSApp.isActive, window.isKeyWindow, window.makeFirstResponder(self) else {
            self.session?.captureMouse = false
            return
        }
        captureGeneration &+= 1
        let generation = captureGeneration
        capturePending = true
        relativeModeAcknowledged = false
        let heldButtons = buttons
        buttons = CSInputButton(rawValue: 0)
        heldModifiers.removeAll(); pressedKeys.removeAll()
        // This operation releases the old absolute-mode state and requests
        // SPICE server mode on the same queue as motion and buttons.
        session.inputDispatcher.release(input, buttons: heldButtons, relative: true)
        confirmCapture(input: input, generation: generation, attemptsLeft: 15)
    }

    private func confirmCapture(input: CSInput, generation: UInt64, attemptsLeft: Int) {
        session?.inputDispatcher.mouseMode(input) { [weak self] relative in
            guard let self, self.capturePending, self.captureGeneration == generation,
                  self.mouseInput === input, self.session?.captureMouse == true else { return }
            guard NSApp.isActive, self.window?.isKeyWindow == true else { self.releaseInput(); return }
            if relative {
                // Put the fixed host pointer inside this window even when the
                // capture command was chosen from its toolbar or menu.
                guard let window = self.window, let primaryScreen = NSScreen.screens.first else {
                    self.releaseInput(); return
                }
                let center = self.convert(CGPoint(x: self.bounds.midX, y: self.bounds.midY), to: nil)
                let screenPoint = window.convertPoint(toScreen: center)
                let quartzPoint = CGPoint(x: screenPoint.x, y: primaryScreen.frame.maxY - screenPoint.y)
                let warp = CGWarpMouseCursorPosition(quartzPoint)
                guard warp == .success else {
                    self.releaseInput()
                    self.session?.captureError = "macOS could not position the captured pointer."
                    return
                }
                let result = CGAssociateMouseAndMouseCursorPosition(0)
                guard result == .success else {
                    self.releaseInput()
                    self.session?.captureError = "macOS did not allow mouse capture."
                    return
                }
                self.capturePending = false
                self.captured = true
                self.relativeModeAcknowledged = true
                self.hideCursor()
                self.logger.info("Mouse capture active; SPICE relative mode acknowledged")
            } else if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, self.capturePending, self.captureGeneration == generation else { return }
                    self.confirmCapture(input: input, generation: generation, attemptsLeft: attemptsLeft - 1)
                }
            } else {
                self.releaseInput()
                self.session?.captureError = "Windows did not accept relative mouse mode. Capture was released."
                self.logger.error("Mouse capture released: SPICE relative mode was not acknowledged")
            }
        }
    }

    private func releaseInput() {
        captureGeneration &+= 1
        let wasCaptured = captured
        captured = false; capturePending = false; relativeModeAcknowledged = false
        if wasCaptured { CGAssociateMouseAndMouseCursorPosition(1) }
        if let input = mouseInput, let session {
            session.inputDispatcher.release(input, buttons: buttons)
        }
        buttons = CSInputButton(rawValue: 0)
        heldModifiers.removeAll(); pressedKeys.removeAll()
        if session?.captureMouse == true { session?.captureMouse = false }
        showCursor()
    }
    private func handleHostShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == "f", event.modifierFlags.contains(.control) {
            if !event.isARepeat { releaseInput(); window?.toggleFullScreen(nil) }
            return true
        }
        if key == "q" {
            if !event.isARepeat { releaseInput(); NSApp.terminate(nil) }
            return true
        }
        return false
    }
    private func sendKey(_ code: Int32, pressed: Bool) {
        guard let input = mouseInput, let session else { return }
        session.inputDispatcher.key(input, pressed: pressed, code: code)
    }
    private func send(_ action: @escaping (CSInput) -> Void) {
        guard let input = mouseInput, let session else { return }
        session.inputDispatcher.submit(input, action)
    }
}
