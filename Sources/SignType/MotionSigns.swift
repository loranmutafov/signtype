import CoreGraphics
import Foundation

// MARK: - Body-centred frame

/// A coordinate frame anchored on the signer's upper body:
/// origin at the midpoint of the shoulders, x along the shoulders, y up,
/// 1 unit = shoulder width. Falls back to the head when shoulders are out of frame.
struct BodyFrame {
    let origin: CGPoint
    let xAxis: CGPoint
    let yAxis: CGPoint
    let scale: Double

    /// Whether this frame came from real body landmarks (false = image-space fallback).
    let anchored: Bool

    /// Image-space fallback when no body is visible: origin a little below the image centre,
    /// 1 unit ≈ 0.45 of the image width (roughly a torso in a laptop webcam).
    init(fallbackFor hand: HandPose) {
        origin = CGPoint(x: 0.5, y: 0.35)
        xAxis = CGPoint(x: 1, y: 0)
        yAxis = CGPoint(x: 0, y: 1)
        scale = 0.45
        anchored = false
    }

    init?(body: BodyPose?) {
        guard let body else { return nil }
        anchored = true
        if let l = body.point(.leftShoulder), let r = body.point(.rightShoulder) {
            let dx = Double(l.x - r.x), dy = Double(l.y - r.y)
            let w = (dx * dx + dy * dy).squareRoot()
            guard w > 0.02 else { return nil }
            origin = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
            xAxis = CGPoint(x: dx / w, y: dy / w)
            scale = w
        } else if let nose = body.point(.nose), let le = body.point(.leftEar), let re = body.point(.rightEar) {
            // Shoulder width ≈ 2.3 × ear-to-ear; shoulders sit ≈ 0.55 shoulder widths below the nose.
            let dx = Double(le.x - re.x), dy = Double(le.y - re.y)
            let ears = (dx * dx + dy * dy).squareRoot()
            guard ears > 0.01 else { return nil }
            let w = ears * 2.3
            xAxis = CGPoint(x: dx / ears, y: dy / ears)
            let up = CGPoint(x: -xAxis.y, y: xAxis.x)
            origin = CGPoint(x: nose.x - up.x * w * 0.55, y: nose.y - up.y * w * 0.55)
            scale = w
        } else {
            return nil
        }
        // y axis: x rotated 90° so that "up" in the image is positive when the signer is upright.
        var up = CGPoint(x: -xAxis.y, y: xAxis.x)
        if up.y < 0 { up = CGPoint(x: -up.x, y: -up.y) }
        yAxis = up
    }

    func map(_ p: CGPoint) -> (x: Double, y: Double) {
        let dx = Double(p.x - origin.x), dy = Double(p.y - origin.y)
        return (
            (dx * Double(xAxis.x) + dy * Double(xAxis.y)) / scale,
            (dx * Double(yAxis.x) + dy * Double(yAxis.y)) / scale
        )
    }
}

// MARK: - Per-frame motion features

/// One frame of the motion stream: both hands in body coordinates.
/// Slot 0 = right hand, slot 1 = left hand. 14 numbers per slot:
///   present, wrist x, wrist y, five fingertip offsets from the wrist (÷ palm length, ×0.5),
///   and apparent palm size (a proxy for distance from the camera, so "towards the camera"
///   signs like THANK-YOU register as motion).
struct MotionFrame {
    static let perSlot = 14
    static let length = perSlot * 2

    let vector: [Float]
    let wrists: [CGPoint?]   // body coords, per slot
    let sizes: [Double?]     // palm length in body units, per slot
    let time: CFTimeInterval

    /// True when the body was actually tracked (vs. the image-space fallback).
    let anchored: Bool

    init?(observation: FrameObservation, time: CFTimeInterval) {
        guard let first = observation.hands.first else { return nil }
        let frame = BodyFrame(body: observation.body) ?? BodyFrame(fallbackFor: first)
        anchored = frame.anchored

        var slots: [HandPose?] = [nil, nil]
        var unknown: [HandPose] = []
        for h in observation.hands {
            if h.chiralityKnown {
                let i = h.isLeft ? 1 : 0
                if slots[i] == nil { slots[i] = h } else { unknown.append(h) }
            } else {
                unknown.append(h)
            }
        }
        for h in unknown {
            if let free = slots.firstIndex(where: { $0 == nil }) { slots[free] = h }
        }

        var v = [Float](repeating: 0, count: MotionFrame.length)
        var wrists: [CGPoint?] = [nil, nil]
        var sizes: [Double?] = [nil, nil]
        for (i, hand) in slots.enumerated() {
            guard let hand else {
                // Absent hand: rest position below the shoulders, so "hand down" ≈ "hand gone".
                v[i * MotionFrame.perSlot + 1] = i == 0 ? 0.45 : -0.45
                v[i * MotionFrame.perSlot + 2] = -0.9
                continue
            }
            let base = i * MotionFrame.perSlot
            let wrist = hand.points[Joint.wrist.rawValue]
            let w = frame.map(wrist)
            v[base] = 1
            v[base + 1] = Float(w.x)
            v[base + 2] = Float(w.y)
            wrists[i] = CGPoint(x: w.x, y: w.y)

            let mcp = hand.points[Joint.middleMCP.rawValue]
            let palm = max(Double(hypot(mcp.x - wrist.x, mcp.y - wrist.y)) / frame.scale, 1e-3)
            for (k, tip) in [Joint.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip].enumerated() {
                let t = frame.map(hand.points[tip.rawValue])
                v[base + 3 + k * 2] = Float((t.x - w.x) / palm * 0.5)
                v[base + 4 + k * 2] = Float((t.y - w.y) / palm * 0.5)
            }
            v[base + 13] = Float(palm)
            sizes[i] = palm
        }
        vector = v
        self.wrists = wrists
        self.sizes = sizes
        self.time = time
    }
}

struct MotionSegment {
    var frames: [MotionFrame]
    var pathLength: Double
    var start: CFTimeInterval { frames.first?.time ?? 0 }
    var end: CFTimeInterval { frames.last?.time ?? 0 }
    var vectors: [[Float]] { frames.map { $0.vector } }
}

// MARK: - Segmenter: cuts the stream into "the hands did a thing" chunks

/// Watches wrist speed. A segment starts when a hand starts moving and ends once it has been
/// still for a few frames or disappears. Fingerspelling barely moves the wrist, so it does not
/// trigger; whole-word signs do.
final class MotionSegmenter {
    var startSpeed = 0.03      // shoulder widths per frame (or equivalent size change)
    var stopSpeed = 0.015
    var stopFrames = 5
    var preRoll = 3
    var minFrames = 6
    var maxFrames = 75
    var minPathLength = 0.3    // shoulder widths travelled over the whole segment
    /// Frames the hand may vanish (e.g. in front of the face) before a segment is cut.
    var missingGrace = 4

    private var history: [MotionFrame] = []
    private var active: [MotionFrame] = []
    private var still = 0
    private var path = 0.0
    private var ema = 0.0
    private var last: MotionFrame?
    private var missing = 0
    private var smoothSize: [Double?] = [nil, nil]
    private(set) var isActive = false
    /// Smoothed wrist speed of the latest frame (shoulder widths per frame), for diagnostics.
    private(set) var currentSpeed = 0.0

    /// Apparent-size changes are noisy; smooth them and weight them so a real push towards the
    /// camera registers but tracking jitter does not.
    var sizeSmoothing = 0.3
    var sizeWeight = 1.5
    /// Letters are only paused once a segment has travelled this far. Finger changes between
    /// letters move the wrist a little; whole-word signs move it a lot.
    var pauseLettersAfterPath = 0.25

    /// True when a sign is clearly in progress (not just the first jittery frames).
    var isMoving: Bool { isActive && path >= pauseLettersAfterPath }

    func reset() {
        history = []
        active = []
        still = 0
        path = 0
        ema = 0
        last = nil
        missing = 0
        smoothSize = [nil, nil]
        isActive = false
    }

    /// Returns a completed, qualifying segment when one just ended.
    func ingest(_ frame: MotionFrame?) -> MotionSegment? {
        guard let frame else {
            history = []
            currentSpeed = 0
            smoothSize = [nil, nil]
            if isActive {
                missing += 1
                if missing <= missingGrace { return nil }
                return finish()
            }
            last = nil
            return nil
        }
        missing = 0
        var speed = 0.0
        for i in 0..<2 {
            if let last, let a = last.wrists[i], let b = frame.wrists[i] {
                speed = max(speed, Double(hypot(a.x - b.x, a.y - b.y)))
            }
            // Moving towards/away from the camera shows up as the palm growing/shrinking.
            // Smoothed, because the raw size estimate jitters by a few percent at rest.
            if let sb = frame.sizes[i], sb > 0 {
                if let s = smoothSize[i], s > 0 {
                    let ns = (1 - sizeSmoothing) * s + sizeSmoothing * sb
                    speed = max(speed, abs(ns - s) / s * sizeWeight)
                    smoothSize[i] = ns
                } else {
                    smoothSize[i] = sb
                }
            } else {
                smoothSize[i] = nil
            }
        }
        last = frame
        ema = 0.5 * ema + 0.5 * speed
        currentSpeed = ema

        if !isActive {
            if ema > startSpeed {
                isActive = true
                active = history + [frame]
                path = speed
                still = 0
            } else {
                history.append(frame)
                if history.count > preRoll { history.removeFirst() }
            }
            return nil
        }

        active.append(frame)
        path += speed
        still = ema < stopSpeed ? still + 1 : 0
        if still >= stopFrames || active.count >= maxFrames {
            return finish()
        }
        return nil
    }

    private func finish() -> MotionSegment? {
        isActive = false
        missing = 0
        var frames = active
        active = []
        history = []
        let trailing = min(still, max(frames.count - minFrames, 0))
        if trailing > 0 { frames.removeLast(trailing) }
        still = 0
        let length = path
        path = 0
        guard frames.count >= minFrames, length >= minPathLength else { return nil }
        return MotionSegment(frames: frames, pathLength: length)
    }
}

// MARK: - Matcher: dynamic time warping against taught templates

struct MotionTemplate: Codable {
    var label: String
    var frames: [[Float]]
}

struct MotionMatch {
    let label: String
    let confidence: Double
    let distance: Float
}

final class MotionMatcher {
    static let resampleLength = 30

    private(set) var templates: [MotionTemplate] = []
    /// DTW distance (per step) above which nothing matches.
    var maxDistance: Float = 0.6
    private let lock = NSLock()

    var counts: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        var c: [String: Int] = [:]
        for t in templates { c[t.label, default: 0] += 1 }
        return c
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return templates.isEmpty
    }

    func add(label: String, segment: MotionSegment) {
        let resampled = Self.resample(segment.vectors, to: Self.resampleLength)
        lock.lock(); defer { lock.unlock() }
        templates.append(MotionTemplate(label: label, frames: resampled))
    }

    func remove(label: String) {
        lock.lock(); defer { lock.unlock() }
        templates.removeAll { $0.label == label }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        templates = []
    }

    /// Best distance per label, ascending.
    func scores(_ segment: MotionSegment) -> [(String, Float)] {
        let q = Self.resample(segment.vectors, to: Self.resampleLength)
        lock.lock(); defer { lock.unlock() }
        var best: [String: Float] = [:]
        for t in templates {
            let d = Self.dtw(q, t.frames, band: 8)
            if d < best[t.label, default: .greatestFiniteMagnitude] { best[t.label] = d }
        }
        return best.map { ($0.key, $0.value) }.sorted { $0.1 < $1.1 }
    }

    func match(_ segment: MotionSegment) -> MotionMatch? {
        let ranked = scores(segment)
        guard let top = ranked.first, top.1 <= maxDistance else { return nil }
        let closeness = Double(1 - top.1 / maxDistance)
        var margin = 1.0
        if ranked.count > 1 {
            margin = Double(min(1, max(0, (ranked[1].1 - top.1) / (0.25 * maxDistance))))
        }
        let confidence = closeness * (0.6 + 0.4 * margin)
        guard confidence >= 0.4 else { return nil }
        return MotionMatch(label: top.0, confidence: confidence, distance: top.1)
    }

    // MARK: maths

    static func resample(_ frames: [[Float]], to n: Int) -> [[Float]] {
        guard frames.count > 1, n > 1 else { return frames }
        var out: [[Float]] = []
        out.reserveCapacity(n)
        let step = Float(frames.count - 1) / Float(n - 1)
        for i in 0..<n {
            let pos = Float(i) * step
            let a = Int(pos.rounded(.down))
            let b = min(a + 1, frames.count - 1)
            let t = pos - Float(a)
            var v = frames[a]
            if t > 0 {
                for k in 0..<v.count { v[k] = v[k] * (1 - t) + frames[b][k] * t }
            }
            out.append(v)
        }
        return out
    }

    /// Sakoe–Chiba banded DTW; returns cost per alignment step.
    static func dtw(_ a: [[Float]], _ b: [[Float]], band: Int) -> Float {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return .greatestFiniteMagnitude }
        let w = max(band, abs(n - m))
        var prev = [Float](repeating: .greatestFiniteMagnitude, count: m + 1)
        var cur = prev
        prev[0] = 0
        for i in 1...n {
            cur = [Float](repeating: .greatestFiniteMagnitude, count: m + 1)
            let lo = max(1, i - w), hi = min(m, i + w)
            if lo > hi { continue }
            for j in lo...hi {
                let d = distance(a[i - 1], b[j - 1])
                cur[j] = d + min(prev[j], prev[j - 1], cur[j - 1])
            }
            prev = cur
        }
        let total = prev[m]
        return total.isFinite ? total / Float(n + m) : total
    }

    private static func distance(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            let d = a[i] - b[i]
            s += d * d
            i += 1
        }
        return s.squareRoot()
    }

    // MARK: persistence

    static var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SignType", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("motions.json")
    }

    static func loadFromDisk() -> MotionMatcher {
        let m = MotionMatcher()
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode([MotionTemplate].self, from: data) {
            m.templates = decoded
        }
        return m
    }

    func save() {
        lock.lock()
        let snapshot = templates
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.storageURL, options: .atomic)
        }
    }
}

// MARK: - Ordered output

/// Keeps typed output in signing order even when some pieces (Gemma lookups) resolve late.
final class OutputQueue {
    private struct Item {
        let id: Int
        var text: String?
    }

    private let lock = NSLock()
    private var items: [Item] = []
    private var nextID = 0
    private let sink: (String) -> Void

    init(sink: @escaping (String) -> Void) {
        self.sink = sink
    }

    var hasPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return items.contains { $0.text == nil }
    }

    func push(_ text: String) {
        lock.lock()
        items.append(Item(id: nextID, text: text))
        nextID += 1
        let ready = drainLocked()
        lock.unlock()
        ready.forEach(sink)
    }

    func reserve() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID += 1
        items.append(Item(id: id, text: nil))
        return id
    }

    func resolve(_ id: Int, with text: String) {
        lock.lock()
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].text = text }
        let ready = drainLocked()
        lock.unlock()
        ready.forEach(sink)
    }

    /// Drops anything still unresolved (used when giving up on the cloud).
    func cancelPending() {
        lock.lock()
        items = items.filter { $0.text != nil }
        let ready = drainLocked()
        lock.unlock()
        ready.forEach(sink)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        items = []
    }

    private func drainLocked() -> [String] {
        var out: [String] = []
        while let first = items.first, let t = first.text {
            items.removeFirst()
            if !t.isEmpty { out.append(t) }
        }
        return out
    }
}
