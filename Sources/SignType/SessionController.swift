import AppKit
import AVFoundation
import Combine
import QuartzCore

/// Owns the camera → Vision → classifier → decoder → typist pipeline and the overlay.
/// Public methods are main-thread; frame handling runs on the camera queue.
final class SessionController: ObservableObject {
    enum Activity { case idle, signing, teaching, processing }

    let settings = Settings.shared
    let camera = CameraSession()
    let tracker = HandPoseTracker()
    let knn = KNNClassifier.loadFromDisk()
    let rules = RuleClassifier()
    private(set) lazy var classifier = EnsembleClassifier(knn: knn, rules: rules)
    let decoder = Decoder()
    let typist = Typist()
    private let encoder = FrameEncoder()

    private(set) var overlay: OverlayPanel?

    /// Fires on the main thread whenever activity changes (menu refresh).
    var onActivityChange: ((Activity) -> Void)?
    /// Main-thread hook used by the teach window.
    var onFeatures: ((HandFeatures?, Prediction?) -> Void)?

    // Shared between main and the camera queue.
    private let lock = NSLock()
    private var _activity: Activity = .idle
    private var activeMode: Mode = .live
    private var buffer = ""
    private var frames: [Data] = []
    private var lastHandSeen: CFTimeInterval = 0

    // Camera-queue only.
    private var lastProcessed: CFTimeInterval = 0
    private var lastCapture: CFTimeInterval = 0

    // Main only.
    private var startedAt: CFTimeInterval = 0
    private var idleTimer: Timer?

    init() {
        camera.onFrame = { [weak self] pb in self?.handleFrame(pb) }
    }

    var activity: Activity {
        lock.lock(); defer { lock.unlock() }
        return _activity
    }

    private func setActivity(_ a: Activity) {
        lock.lock(); _activity = a; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.onActivityChange?(a)
        }
    }

    var transcript: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    // MARK: - Public controls (main thread)

    func toggle() {
        switch activity {
        case .idle: startSigning()
        case .signing: stopSigning()
        case .teaching, .processing: break
        }
    }

    func startSigning() {
        guard activity == .idle else { return }
        prepareCamera { [weak self] ok in
            guard let self, ok else { return }
            if !Permissions.accessibilityTrusted {
                Permissions.requestAccessibility()
            }
            self.decoder.stableFrames = self.settings.stableFrames
            self.decoder.reset()
            self.lock.lock()
            self.buffer = ""
            self.frames = []
            self.lastHandSeen = 0
            self.activeMode = self.settings.mode
            self.lock.unlock()
            self.startedAt = CACurrentMediaTime()
            self.setActivity(.signing)
            let status: String
            switch self.settings.mode {
            case .live: status = "Live · typing as you sign · fn ×3 to stop"
            case .batch: status = "Batch · types when you stop · fn ×3 to stop"
            case .gemma: status = "Gemma · sends frames when you stop · fn ×3 to stop"
            }
            self.showOverlay(status: status)
            self.camera.start()
            self.startIdleTimer()
        }
    }

    func stopSigning() {
        guard activity == .signing else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        camera.stop()

        lock.lock()
        let text = buffer.trimmingCharacters(in: .whitespaces)
        let captured = frames
        let mode = activeMode
        lock.unlock()

        switch mode {
        case .live:
            finish()
        case .batch:
            finish()
            if !text.isEmpty { typist.type(text) }
        case .gemma:
            let key = settings.gemmaApiKey.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                finish()
                if !text.isEmpty { typist.type(text) }
                Self.alert("No Gemma API key set", "Typed the on-device result instead. Add a key under SignType ▸ Settings… to use Gemma 4.")
                return
            }
            setActivity(.processing)
            overlay?.setStatus("Asking Gemma 4 (\(captured.count) frames)…")
            let client = GemmaClient(apiKey: key, model: settings.gemmaModel)
            Task { [weak self] in
                guard let self else { return }
                var result = ""
                var failure: String? = nil
                do {
                    result = try await client.transcribe(frames: captured, hint: text)
                } catch {
                    failure = error.localizedDescription
                }
                let typed = result
                let failed = failure
                await MainActor.run {
                    self.finish()
                    if !typed.isEmpty {
                        self.typist.type(typed)
                    } else {
                        if !text.isEmpty { self.typist.type(text) }
                        if let failed {
                            Self.alert("Gemma request failed", "\(failed)\n\nTyped the on-device result instead.")
                        }
                    }
                }
            }
        }
    }

    func startTeaching() {
        guard activity == .idle else { return }
        prepareCamera { [weak self] ok in
            guard let self, ok else { return }
            self.setActivity(.teaching)
            self.showOverlay(status: "Teach mode · nothing is typed")
            self.camera.start()
        }
    }

    func stopTeaching() {
        guard activity == .teaching else { return }
        camera.stop()
        knn.save()
        finish()
    }

    // MARK: - Internals

    private func prepareCamera(_ done: @escaping (Bool) -> Void) {
        Permissions.requestCamera { [weak self] ok in
            guard let self else { return done(false) }
            guard ok else {
                Self.alert("Camera access needed", "Allow SignType to use the camera in System Settings ▸ Privacy & Security ▸ Camera.")
                Permissions.openSystemSettings(pane: "Privacy_Camera")
                return done(false)
            }
            do {
                try self.camera.configure()
            } catch {
                Self.alert("No camera found", "\(error)")
                return done(false)
            }
            done(true)
        }
    }

    private func finish() {
        setActivity(.idle)
        overlay?.hide()
    }

    private func showOverlay(status: String) {
        if overlay == nil {
            overlay = OverlayPanel(session: camera.session)
        }
        overlay?.setStatus(status)
        overlay?.update(pose: nil, prediction: nil, holdProgress: 0, text: "")
        overlay?.show()
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.activity == .signing else { return }
            let now = CACurrentMediaTime()
            self.lock.lock()
            let seen = self.lastHandSeen
            self.lock.unlock()
            if seen > 0 {
                if now - seen > self.settings.autoStopSeconds { self.stopSigning() }
            } else if now - self.startedAt > 20 {
                // Never saw a hand – don't leave the camera on forever.
                self.stopSigning()
            }
        }
    }

    /// Camera queue.
    private func handleFrame(_ pb: CVPixelBuffer) {
        let act = activity
        guard act == .signing || act == .teaching else { return }
        let now = CACurrentMediaTime()
        guard now - lastProcessed >= 1.0 / 15.0 else { return }
        lastProcessed = now

        let pose = tracker.detect(in: pb)
        let features = pose.map { HandFeatures(pose: $0) }
        let prediction = features.flatMap { classifier.classify($0) }

        if act == .signing {
            lock.lock()
            let mode = activeMode
            if pose != nil { lastHandSeen = now }
            lock.unlock()

            if mode == .gemma, now - lastCapture >= 0.5, let jpg = encoder.jpeg(pb) {
                lastCapture = now
                lock.lock()
                frames.append(jpg)
                if frames.count > 80 { frames.removeFirst() }
                lock.unlock()
            }

            if let event = decoder.ingest(prediction) {
                let piece: String
                switch event {
                case .letter(let l): piece = l
                case .space: piece = " "
                }
                lock.lock()
                buffer += piece
                lock.unlock()
                if mode == .live { typist.type(piece) }
            }
        }

        let progress = decoder.holdProgress
        let text = transcript
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlay?.update(pose: pose, prediction: prediction, holdProgress: progress, text: text)
            self.onFeatures?(features, prediction)
        }
    }

    static func alert(_ title: String, _ message: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = title
            a.informativeText = message
            a.alertStyle = .warning
            a.runModal()
        }
    }
}
