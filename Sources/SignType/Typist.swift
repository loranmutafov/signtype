import CoreGraphics
import Foundation

/// Types text into whatever app currently has keyboard focus by posting synthetic
/// keyboard events. Needs Accessibility permission.
final class Typist {
    private let source = CGEventSource(stateID: .combinedSessionState)

    func type(_ text: String) {
        guard !text.isEmpty else { return }
        let utf16 = Array(text.utf16)
        // CGEventKeyboardSetUnicodeString is happiest with short strings.
        var i = 0
        while i < utf16.count {
            let chunk = Array(utf16[i..<min(i + 16, utf16.count)])
            postUnicode(chunk)
            i += 16
            usleep(6_000)
        }
    }

    func backspace(_ n: Int = 1) {
        for _ in 0..<max(0, n) {
            tap(virtualKey: 51)
            usleep(4_000)
        }
    }

    private func postUnicode(_ chars: [UniChar]) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        chars.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func tap(virtualKey: CGKeyCode) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
