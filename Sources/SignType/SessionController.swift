import AppKit
import AVFoundation
import Combine
import QuartzCore

/// Owns the camera → Vision → classifier/matcher → decoder → typist pipeline and the overlay.
/// Public methods are main-thread; frame handling runs on the camera queue.
final class SessionController: ObservableObject {
    enum Activity { case idle, signing, teaching, processing }

    /// What the overlay should show big, besides the current letter.
    enum Flash {
        case word(String)
        case unknown
        case thinking
    }

    let settings = Settings.shared
    let camera = CameraSession()
    let tracker = PoseTracker()
    let knn = KNNClassifier.loadFromDisk()
    let rules = RuleClassifier()
    private(set) lazy var classifier = EnsembleClassifier(knn: knn, rules: rules)
    let decoder = Decoder()
    let segmenter = MotionSegmenter()
    let matcher = MotionMatcher.loadFromDisk()
    let typist = Typist()
    private let encoder = FrameEncoder()
    private lazy var output = OutputQueue { [weak self] text in self?.typist.type(text) }

    private(set) var overlay: OverlayPanel?

    /// Fires on the main thread whenever activity changes (menu refresh).
    var onActivityChange: ((Activity) -> Void)?
    /// Main-thread hook used by the teach window: per processed frame.
    var onFeatures: ((HandFeatures?, Prediction?) -> Void)?
    /// Main-thread hook used by the teach window: a motion segment just completed.
    var onSegment: ((MotionSegment) -> Void)?

    // Shared between main and the camera queue.
    private let lock = NSLock()
    private var _activity: Activity = .idle
    private var activeMode: Mode = .live
    private var buffer = ""
    private var frames: [Data] = []                              // batch Gemma: whole session
    private var recent: [(time: CFTimeInterval, jpeg: Data)] = [] // hybrid: last few seconds
    private var lastHandSeen: CFTimeInterval = 0
    private var pendingGemma = 0

    // Camera-queue only.
    private var lastProcessed: CFTimeInterval = 0
    private var lastCapture: CFTimeInterval = 0
    private var lastDiag: CFTimeInterval = 0

    // Main only.
    private var startedAt: CFTimeInterval = 0
    private var idleTimer: Timer?
    private var drainTimer: Timer?

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

    /// Hotkey entry point. A stop that arrives within the first moments of a session is
    /// ignored so a stray extra fn event cannot cancel what it just started.
    func toggle() {
        switch activity {
        case .idle:
            Log.session.info("toggle → start")
            startSigning()
        case .signing:
            if CACurrentMediaTime() - startedAt < minimumSessionSeconds {
                Log.session.info("toggle → stop ignored (session just started)")
                return
            }
            Log.session.info("toggle → stop")
            stopSigning()
        case .teaching, .processing:
            break
        }
    }

    var minimumSessionSeconds: Double = 1.5

    func startSigning() {
        guard activity == .idle else { return }
        prepareCamera { [weak self] ok in
            guard let self, ok else { return }
            if !Permissions.accessibilityTrusted {
                Permissions.requestAccessibility()
            }
            let mode = self.settings.mode
            self.decoder.stableFrames = self.settings.stableFrames
            self.decoder.reset()
            self.segmenter.reset()
            self.output.reset()
            self.lock.lock()
            self.buffer = ""
            self.frames = []
            self.recent = []
            self.lastHandSeen = 0
            self.pendingGemma = 0
            self.activeMode = mode
            self.lock.unlock()
            self.startedAt = CACurrentMediaTime()
            self.setActivity(.signing)
            let status: String
            switch mode {
            case .live: status = "Live · typing as you sign · fn ×3 to stop"
            case .batch: status = "Batch · types when you stop · fn ×3 to stop"
            case .gemma: status = "Gemma · sends frames when you stop · fn ×3 to stop"
            case .hybrid: status = "Hybrid · on-device, Gemma for unknown signs · fn ×3 to stop"
            }
            if mode.usesGemma && self.settings.gemmaApiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                Log.session.info("mode \(mode.rawValue) selected without an API key")
            }
            self.showOverlay(status: status)
            self.camera.start()
            self.startIdleTimer()
        }
    }

    func stopSigning() {
        guard activity == .signing else { return }
        Log.session.info("stopSigning after \(CACurrentMediaTime() - self.startedAt, format: .fixed(precision: 1))s")
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
        case .hybrid:
            // Let in-flight Gemma lookups land (in order) before closing the session.
            if output.hasPending {
                setActivity(.processing)
                overlay?.setStatus("Waiting for Gemma…")
                let deadline = CACurrentMediaTime() + 12
                drainTimer?.invalidate()
                drainTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
                    guard let self else { t.invalidate(); return }
                    if !self.output.hasPending || CACurrentMediaTime() > deadline {
                        t.invalidate()
                        self.output.cancelPending()
                        self.finish()
                    }
                }
            } else {
                finish()
            }
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
            self.segmenter.reset()
            self.setActivity(.teaching)
            self.showOverlay(status: "Teach mode · nothing is typed")
            self.camera.start()
        }
    }

    func stopTeaching() {
        guard activity == .teaching else { return }
        camera.stop()
        knn.save()
        matcher.save()
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
        drainTimer?.invalidate()
        drainTimer = nil
        setActivity(.idle)
        overlay?.hide()
    }

    private func showOverlay(status: String) {
        if overlay == nil {
            overlay = OverlayPanel(session: camera.session)
        }
        overlay?.setStatus(status)
        overlay?.update(observation: nil, prediction: nil, holdProgress: 0, text: "", inMotion: false)
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
                if now - seen > self.settings.autoStopSeconds {
                    Log.session.info("auto-stop: no hand for \(self.settings.autoStopSeconds)s")
                    self.stopSigning()
                }
            } else if now - self.startedAt > 20 {
                // Never saw a hand – don't leave the camera on forever.
                Log.session.info("auto-stop: never saw a hand")
                self.stopSigning()
            }
        }
    }

    // MARK: - Frame pipeline (camera queue)

    private func handleFrame(_ pb: CVPixelBuffer) {
        let act = activity
        guard act == .signing || act == .teaching else { return }
        let now = CACurrentMediaTime()
        guard now - lastProcessed >= 1.0 / 15.0 else { return }
        lastProcessed = now

        let observation = tracker.detect(in: pb)
        let primary = observation.primaryHand
        let features = primary.map { HandFeatures(pose: $0) }
        let prediction = features.flatMap { classifier.classify($0) }

        // Motion stream: both hands in body coordinates → segments of "the hands did a thing".
        let motion = MotionFrame(observation: observation, time: now)
        let segment = segmenter.ingest(motion)
        let inMotion = segmenter.isMoving
        if segment != nil { matcher.maxDistance = Float(settings.matchDistance) }

        if now - lastDiag >= 1 {
            lastDiag = now
            let bodyInfo = observation.body?.summary ?? "none"
            Log.session.debug("hands=\(observation.hands.count) body=[\(bodyInfo)] anchored=\(motion?.anchored ?? false) speed=\(self.segmenter.currentSpeed, format: .fixed(precision: 3)) active=\(inMotion) words=\(self.matcher.counts.values.reduce(0, +))")
        }

        var flash: Flash? = nil

        if act == .signing {
            lock.lock()
            let mode = activeMode
            if primary != nil { lastHandSeen = now }
            lock.unlock()

            captureFrames(pb, now: now, mode: mode)

            if inMotion {
                decoder.pause()
            } else if let event = decoder.ingest(prediction) {
                let piece: String
                switch event {
                case .letter(let l): piece = l
                case .space: piece = " "
                }
                emit(piece, mode: mode)
            }

            if let segment {
                flash = handleSegment(segment, mode: mode)
            }
        } else if let segment {
            // Teaching: hand the segment to the window; also show what it would have matched.
            if let m = matcher.match(segment) { flash = .word(m.label) } else { flash = .unknown }
            DispatchQueue.main.async { [weak self] in self?.onSegment?(segment) }
        }

        let progress = decoder.holdProgress
        let text = transcript
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlay?.update(observation: observation, prediction: prediction, holdProgress: progress, text: text, inMotion: inMotion)
            if let flash { self.overlay?.flash(flash) }
            self.onFeatures?(features, prediction)
        }
    }

    /// Keep JPEGs for the cloud paths. Batch: the whole session at 2 fps. Hybrid: the last
    /// few seconds at 4 fps so an unknown segment can be sent with a little context.
    private func captureFrames(_ pb: CVPixelBuffer, now: CFTimeInterval, mode: Mode) {
        guard mode.usesGemma else { return }
        let interval = mode == .hybrid ? 0.25 : 0.5
        guard now - lastCapture >= interval, let jpg = encoder.jpeg(pb) else { return }
        lastCapture = now
        lock.lock()
        if mode == .hybrid {
            recent.append((now, jpg))
            while let first = recent.first, now - first.time > 6 { recent.removeFirst() }
        } else {
            frames.append(jpg)
            if frames.count > 80 { frames.removeFirst() }
        }
        lock.unlock()
    }

    private func emit(_ piece: String, mode: Mode) {
        lock.lock()
        buffer += piece
        lock.unlock()
        if mode.typesLive { output.push(piece) }
    }

    /// A motion segment finished while signing. Returns what to flash in the overlay.
    private func handleSegment(_ segment: MotionSegment, mode: Mode) -> Flash {
        if let m = matcher.match(segment) {
            Log.session.info("segment matched '\(m.label)' d=\(m.distance, format: .fixed(precision: 3)) conf=\(m.confidence, format: .fixed(precision: 2))")
            decoder.markExternalOutput()
            emit(m.label + " ", mode: mode)
            return .word(m.label)
        }

        Log.session.info("segment unmatched (\(segment.frames.count) frames, path \(segment.pathLength, format: .fixed(precision: 2)))")
        decoder.markExternalOutput()
        guard mode == .hybrid else { return .unknown }

        let key = settings.gemmaApiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return .unknown }

        lock.lock()
        let clip = recent.filter { $0.time >= segment.start - 0.3 && $0.time <= segment.end + 0.1 }.map { $0.jpeg }
        let context = buffer
        pendingGemma += 1
        lock.unlock()
        guard !clip.isEmpty else { return .unknown }

        let slot = output.reserve()
        let client = GemmaClient(apiKey: key, model: settings.gemmaModel)
        Task { [weak self] in
            var word = ""
            do {
                word = try await client.gloss(frames: clip, contextBefore: context)
            } catch {
                Log.session.error("Gemma gloss failed: \(error.localizedDescription)")
            }
            guard let self else { return }
            self.completeGemmaLookup(slot: slot, word: word)
        }
        return .thinking
    }

    /// Synchronous tail of a Hybrid lookup (keeps NSLock out of async contexts).
    private func completeGemmaLookup(slot: Int, word: String) {
        lock.lock()
        pendingGemma -= 1
        if !word.isEmpty { buffer += word + " " }
        lock.unlock()
        output.resolve(slot, with: word.isEmpty ? "" : word + " ")
        let shown: Flash = word.isEmpty ? .unknown : .word(word)
        DispatchQueue.main.async { [weak self] in self?.overlay?.flash(shown) }
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
