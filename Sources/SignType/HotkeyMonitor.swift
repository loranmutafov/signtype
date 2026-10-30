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

    /// Taps must all land inside this many seconds.
    var window: TimeInterval = 0.8
    var requiredTaps = 3

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

        let isDown = event.flags.contains(.maskSecondaryFn)
        if isDown && !fnDown {
            fnDown = true
            let now = Date().timeIntervalSinceReferenceDate
            tapTimes = tapTimes.filter { now - $0 < window }
            tapTimes.append(now)
            if tapTimes.count >= requiredTaps {
                tapTimes.removeAll()
                DispatchQueue.main.async { [onTriple] in onTriple() }
            }
        } else if !isDown {
            fnDown = false
        }
    }
}
