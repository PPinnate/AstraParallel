import CocoaSpiceNoUsb
import Foundation
import CoreGraphics
import AstraCore

/// Orders complete input operations without blocking the AppKit event thread.
final class InputDispatcher {
    private let queue = DispatchQueue(label: "local.astra.input", qos: .userInteractive)
    private var lastKeyTime: TimeInterval = 0
    private let epoch = InputEpoch()
    var onOverflow: (() -> Void)?
    let timings = TimingMetrics()
    private let pointerQueue = DispatchQueue(label: "local.astra.pointer", qos: .userInteractive)
    private let pointerLock = NSLock()
    private var activeBatch: PointerBatch?
    // Accessed only on pointerQueue; sub-pixel motion survives batch boundaries.
    private var relativeMotion = RelativeMouseMotion()
    private weak var relativeInput: CSInput?
    private struct PointerEvent {
        let input: CSInput
        var point: CGPoint
        let buttons: CSInputButton
        let relative: Bool
        let enqueued: TimeInterval
        let epoch: UInt64
    }
    private final class PointerBatch {
        var event: PointerEvent
        init(_ event: PointerEvent) { self.event = event }
    }

    /// Consecutive motion coalesces, while buttons form ordering boundaries.
    /// Relative deltas accumulate; absolute motion keeps the newest position.
    func pointer(_ input: CSInput, point: CGPoint, buttons: CSInputButton, relative: Bool) {
        guard point.x.isFinite, point.y.isFinite else { return }
        pointerLock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let token = epoch.current
        if let batch = activeBatch, batch.event.epoch == token, batch.event.input === input,
           batch.event.relative == relative, batch.event.buttons == buttons {
            let old = batch.event
            let updated = relative ? CGPoint(x: old.point.x + point.x, y: old.point.y + point.y) : point
            batch.event = PointerEvent(input: input, point: updated, buttons: buttons,
                                       relative: relative, enqueued: relative ? old.enqueued : now, epoch: token)
            pointerLock.unlock()
            return
        }
        let batch = PointerBatch(PointerEvent(input: input, point: point, buttons: buttons,
                                               relative: relative, enqueued: now, epoch: token))
        activeBatch = batch
        pointerLock.unlock()
        pointerQueue.async {
            self.pointerLock.lock()
            let event = batch.event
            if self.activeBatch === batch { self.activeBatch = nil }
            self.pointerLock.unlock()
            guard self.epoch.isCurrent(event.epoch), CSMain.shared.running else { return }
            let started = ProcessInfo.processInfo.systemUptime
            self.timings.add("pointer_queue", milliseconds: (started - event.enqueued) * 1000)
            CSMain.shared.sync {
                guard self.epoch.isCurrent(event.epoch) else { return }
                if event.relative {
                    if self.relativeInput !== event.input {
                        self.relativeMotion.reset()
                        self.relativeInput = event.input
                    }
                    let motion = self.relativeMotion.consume(event.point)
                    if motion != .zero { event.input.sendMouseMotion(event.buttons, relativePoint: motion) }
                } else {
                    self.relativeMotion.reset()
                    event.input.sendMousePosition(event.buttons, absolutePoint: event.point)
                }
            }
            self.timings.add("pointer_spice_dispatch", milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
    }

    func mouseButton(_ input: CSInput, button: CSInputButton, buttons: CSInputButton,
                     pressed: Bool, absolutePoint: CGPoint?) {
        pointerOperation(input) {
            if let point = absolutePoint {
                var before = buttons
                if pressed { before.remove(button) } else { before.insert(button) }
                input.sendMousePosition(before, absolutePoint: point)
            }
            input.sendMouseButton(button, mask: buttons, pressed: pressed)
        }
    }

    func scroll(_ input: CSInput, buttons: CSInputButton, delta: CGFloat) {
        pointerOperation(input) {
            input.sendMouseScroll(CSInputScroll(rawValue: 2)!, buttonMask: buttons, dy: delta)
        }
    }

    /// Mode changes cannot overtake queued motion or button releases.
    func setMouseMode(_ input: CSInput, relative: Bool) {
        pointerOperation(input) {
            self.relativeMotion.reset()
            self.relativeInput = input
            input.requestMouseMode(relative)
        }
    }

    /// Reads acknowledgement on the SPICE context, never on the AppKit thread.
    func mouseMode(_ input: CSInput, completion: @escaping (Bool) -> Void) {
        pointerQueue.async {
            var relative = false
            if CSMain.shared.running { CSMain.shared.sync { relative = input.serverModeCursor } }
            DispatchQueue.main.async { completion(relative) }
        }
    }

    /// Cancel stale queued work first, then release the keys/buttons already sent.
    func release(_ input: CSInput, buttons: CSInputButton, relative: Bool = false) {
        epoch.cancel()
        pointerLock.lock(); activeBatch = nil; pointerLock.unlock()
        let began = ProcessInfo.processInfo.systemUptime
        submit(input) { $0.releaseKeys() }
        pointerOperation(input) {
            var remaining = buttons
            for raw: UInt in [1, 2, 4, 32, 64] {
                let button = CSInputButton(rawValue: raw)
                if remaining.contains(button) {
                    remaining.remove(button)
                    input.sendMouseButton(button, mask: remaining, pressed: false)
                }
            }
            self.relativeMotion.reset()
            self.relativeInput = input
            input.requestMouseMode(relative)
            self.timings.add("release_queue", milliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000)
        }
    }

    private func pointerOperation(_ input: CSInput, _ action: @escaping () -> Void) {
        pointerLock.lock(); activeBatch = nil; pointerLock.unlock()
        let token = epoch.current
        let enqueued = ProcessInfo.processInfo.systemUptime
        // Buttons and mode changes see earlier keys/modifiers, without making
        // ordinary motion wait behind the keyboard's deliberate pacing.
        let keysReady = DispatchGroup()
        keysReady.enter()
        queue.async { keysReady.leave() }
        pointerQueue.async {
            keysReady.wait()
            guard self.epoch.isCurrent(token), CSMain.shared.running else { return }
            self.timings.add("button_mode_queue", milliseconds: (ProcessInfo.processInfo.systemUptime - enqueued) * 1000)
            CSMain.shared.sync { if self.epoch.isCurrent(token) { action() } }
        }
    }

    func key(_ input: CSInput, pressed: Bool, code: Int32) {
        guard let token = epoch.enqueue() else {
            // Reject an unbounded backlog. The view releases its tracked state
            // as well, so no modifier can silently remain held after overflow.
            release(input, buttons: CSInputButton(rawValue: 1 | 2 | 4 | 32 | 64))
            DispatchQueue.main.async { self.onOverflow?() }
            return
        }
        let enqueued = ProcessInfo.processInfo.systemUptime
        timings.recordMaximum("keyboard_queue_depth", value: epoch.queued)
        queue.async {
            defer { self.epoch.completed(token) }
            guard self.epoch.isCurrent(token), CSMain.shared.running else { return }
            // The emulated USB HID keyboard has an 8-10 ms interrupt interval
            // and a finite event queue. Bursts from text insertion can otherwise
            // overflow it and lose releases. Keep physical events ordered off
            // the UI thread; an isolated key is sent immediately.
            let remaining = 0.010 - (ProcessInfo.processInfo.systemUptime - self.lastKeyTime)
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
            guard self.epoch.isCurrent(token) else { return }
            self.timings.add("keyboard_queue", milliseconds: (ProcessInfo.processInfo.systemUptime - enqueued) * 1000)
            CSMain.shared.sync {
                if self.epoch.isCurrent(token) { input.send(CSInputKey(rawValue: pressed ? 0 : 1)!, code: code) }
            }
            self.lastKeyTime = ProcessInfo.processInfo.systemUptime
        }
    }

    func submit(_ input: CSInput, _ action: @escaping (CSInput) -> Void) {
        let token = epoch.current
        queue.async {
            guard self.epoch.isCurrent(token), CSMain.shared.running else { return }
            // CSInput's inner async calls execute immediately while this context
            // is owned, so key-up cannot overtake key-down or a modifier change.
            CSMain.shared.sync { if self.epoch.isCurrent(token) { action(input) } }
        }
    }
}
