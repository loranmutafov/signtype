import AVFoundation
import CoreImage
import ImageIO

enum CameraError: Error { case noCamera }

/// Thin AVCaptureSession wrapper. Frames arrive on a private serial queue.
final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "signtype.camera", qos: .userInteractive)
    private var configured = false

    /// Called on the camera queue for every frame.
    var onFrame: ((CVPixelBuffer) -> Void)?

    func configure() throws {
        if configured { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video) else {
            throw CameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        configured = true
    }

    func start() {
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pb)
    }
}

/// Encodes camera frames to small JPEGs for the cloud (Gemma) path.
final class FrameEncoder {
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func jpeg(_ pixelBuffer: CVPixelBuffer, maxWidth: CGFloat = 512, quality: CGFloat = 0.6) -> Data? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let width = image.extent.width
        if width > maxWidth {
            let s = maxWidth / width
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return context.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [qualityKey: quality]
        )
    }
}
