import CoreGraphics
import Foundation

/// Watches the fn (🌐) key globally and fires when it is tapped N times quickly.
/// Uses a listen-only CGEvent tap on flagsChanged, so it needs Input Monitoring
/// (and Accessibility for the typing side of the app).
final class FnTripleTapMonitor {
    private let onTriple: () -> Void
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapTimes: [TimeInterval] = []
    private var fnDown = false
    private var lastDown: TimeInterval = 0
    private var cooldownUntil: TimeInterval = 0

    /// Taps must all land inside this many seconds.
    var window: TimeInterval = 0.8
    var requiredTaps = 3
    /// Two "down" events closer than this are one physical press.
    var duplicateWindow: TimeInterval = 0.04
    /// Ignore fn entirely for this long after a trigger.
    var cooldown: TimeInterval = 1.0

    private static let fnKeyCode: Int64 = 63 // kVK_Function

    init(onTriple: @escaping () -> Void) {
        self.onTriple = onTriple
    }

    /// Returns false if the tap could not be created (usually: Input Monitoring not granted).
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let monitor = Unmanaged<FnTripleTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    var isRunning: Bool { tap != nil }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged else { return }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Self.fnKeyCode else { return }

        let now = Date().timeIntervalSinceReferenceDate
        let isDown = event.flags.contains(.maskSecondaryFn)
        Log.hotkey.debug("fn flagsChanged down=\(isDown) flags=\(event.flags.rawValue, format: .hex) taps=\(self.tapTimes.count)")

        // After a trigger, ignore everything for a moment. Some keyboards/macOS builds emit
        // more than one flagsChanged per physical fn press, which would otherwise count the same
        // three taps as six and immediately toggle back.
        if now < cooldownUntil {
            if !isDown { fnDown = false }
            return
        }

        if isDown && !fnDown {
            // Duplicate "down" within a few ms of the previous one is the same press.
            if now - lastDown < duplicateWindow { return }
            lastDown = now
            fnDown = true
            tapTimes = tapTimes.filter { now - $0 < window }
            tapTimes.append(now)
            if tapTimes.count >= requiredTaps {
                tapTimes.removeAll()
                cooldownUntil = now + cooldown
                Log.hotkey.info("fn triple-tap → toggle")
                DispatchQueue.main.async { [onTriple] in onTriple() }
            }
        } else if !isDown {
            fnDown = false
        }
    }
}
