import AppKit
import ApplicationServices
import AVFoundation

enum Permissions {
    // MARK: Accessibility (needed to post keyboard events into other apps)

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: Input Monitoring (not required when Accessibility is granted; kept for diagnostics)

    static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    // MARK: Camera

    static var cameraStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    static func requestCamera(_ done: @escaping (Bool) -> Void) {
        switch cameraStatus {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { done(ok) }
            }
        default:
            done(false)
        }
    }

    static func openSystemSettings(pane: String) {
        // pane examples: Privacy_Accessibility, Privacy_ListenEvent, Privacy_Camera
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    static var summary: String {
        func mark(_ b: Bool) -> String { b ? "✅" : "❌" }
        return """
        \(mark(cameraStatus == .authorized)) Camera
        \(mark(accessibilityTrusted)) Accessibility (fn key triple-tap + typing into other apps)
        """
    }
}
