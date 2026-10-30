import AppKit
import AVFoundation

/// Small always-on-top camera preview with the hand skeleton, the current letter and the
/// running transcript. It never takes keyboard focus, so typed events keep going to
/// whatever app you were in.
final class OverlayPanel: NSPanel {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let bones = CAShapeLayer()
    private let tips = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let ringTrack = CAShapeLayer()
    private let letterLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    private static let size = NSSize(width: 340, height: 336)
    private static let videoRect = NSRect(x: 10, y: 86, width: 320, height: 240)

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false

        let root = NSView(frame: NSRect(origin: .zero, size: Self.size))
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.94).cgColor
        contentView = root

        // Camera preview (mirrored so it feels like a mirror).
        let videoView = NSView(frame: Self.videoRect)
        videoView.wantsLayer = true
        previewLayer.frame = videoView.bounds
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.cornerRadius = 12
        previewLayer.masksToBounds = true
        if let c = previewLayer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        videoView.layer?.addSublayer(previewLayer)

        bones.frame = previewLayer.bounds
        bones.strokeColor = NSColor.systemGreen.withAlphaComponent(0.9).cgColor
        bones.fillColor = nil
        bones.lineWidth = 2.5
        bones.lineCap = .round
        bones.lineJoin = .round
        previewLayer.addSublayer(bones)

        tips.frame = previewLayer.bounds
        tips.fillColor = NSColor.white.cgColor
        tips.strokeColor = nil
        previewLayer.addSublayer(tips)

        root.addSubview(videoView)

        // Letter + hold-progress ring.
        let ringCenter = CGPoint(x: 44, y: 44)
        let ringPath = CGMutablePath()
        ringPath.addArc(center: ringCenter, radius: 30, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for layer in [ringTrack, ring] {
            layer.path = ringPath
            layer.fillColor = nil
            layer.lineWidth = 4
            layer.lineCap = .round
            root.layer?.addSublayer(layer)
        }
        ringTrack.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        ring.strokeColor = NSColor.systemGreen.cgColor
        ring.strokeEnd = 0

        letterLabel.frame = NSRect(x: 14, y: 14, width: 60, height: 60)
        letterLabel.alignment = .center
        letterLabel.font = .systemFont(ofSize: 36, weight: .bold)
        letterLabel.textColor = .white
        root.addSubview(letterLabel)

        textLabel.frame = NSRect(x: 88, y: 40, width: 242, height: 32)
        textLabel.font = .monospacedSystemFont(ofSize: 20, weight: .medium)
        textLabel.textColor = .white
        textLabel.lineBreakMode = .byTruncatingHead
        textLabel.maximumNumberOfLines = 1
        root.addSubview(textLabel)

        statusLabel.frame = NSRect(x: 88, y: 14, width: 242, height: 20)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        statusLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(statusLabel)

        positionBottomRight()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    func setStatus(_ s: String) {
        statusLabel.stringValue = s
    }

    func update(pose: HandPose?, prediction: Prediction?, holdProgress: Double, text: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if let pose {
            let pts = pose.points.map { p -> CGPoint in
                // Vision: origin bottom-left. Capture-device space: origin top-left.
                previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: p.x, y: 1 - p.y))
            }
            let path = CGMutablePath()
            for (a, b) in Joint.bones {
                guard pose.confidences[a.rawValue] > 0.2, pose.confidences[b.rawValue] > 0.2 else { continue }
                path.move(to: pts[a.rawValue])
                path.addLine(to: pts[b.rawValue])
            }
            bones.path = path

            let dots = CGMutablePath()
            for j in [Joint.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip, .wrist] {
                guard pose.confidences[j.rawValue] > 0.2 else { continue }
                let p = pts[j.rawValue]
                dots.addEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            }
            tips.path = dots
        } else {
            bones.path = nil
            tips.path = nil
        }

        if let prediction {
            letterLabel.stringValue = prediction.label
            letterLabel.textColor = prediction.confidence >= 0.55 ? .white : NSColor.white.withAlphaComponent(0.35)
        } else {
            letterLabel.stringValue = ""
        }
        ring.strokeEnd = CGFloat(holdProgress)
        textLabel.stringValue = text.isEmpty ? "…" : String(text.suffix(18))
    }

    private func positionBottomRight() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        setFrameOrigin(NSPoint(x: vf.maxX - Self.size.width - 24, y: vf.minY + 24))
    }
}
