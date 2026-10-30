import Foundation

struct Prediction: Equatable {
    let label: String
    let confidence: Double
}

protocol SignClassifier {
    func classify(_ f: HandFeatures) -> Prediction?
    /// Scores for every label, highest first. Used by the teach window for debugging.
    func scores(_ f: HandFeatures) -> [(String, Double)]
}

// MARK: - Rule based ASL fingerspelling (static letters, no training data needed)

/// Soft, hand-written geometry rules for the 24 static ASL letters (J and Z need motion
/// and are not recognised). Every rule is a weighted list of fuzzy conditions in 0...1;
/// the letter's score is the weighted mean. It's deliberately forgiving: the temporal
/// decoder and the kNN "teach" layer do the rest.
final class RuleClassifier: SignClassifier {
    struct Rule {
        let label: String
        let conditions: [(weight: Double, value: (HandFeatures) -> Double)]
    }

    let rules: [Rule]

    init() {
        rules = Self.buildRules()
    }

    func scores(_ f: HandFeatures) -> [(String, Double)] {
        rules.map { rule -> (String, Double) in
            var total = 0.0, wsum = 0.0
            for c in rule.conditions {
                total += c.weight * clamp(c.value(f))
                wsum += c.weight
            }
            return (rule.label, wsum > 0 ? total / wsum : 0)
        }
        .sorted { $0.1 > $1.1 }
    }

    func classify(_ f: HandFeatures) -> Prediction? {
        let ranked = scores(f)
        guard let best = ranked.first else { return nil }
        let second = ranked.count > 1 ? ranked[1].1 : 0
        // Confidence blends absolute fit with the margin over the runner-up.
        let margin = clamp((best.1 - second) / 0.15)
        let conf = best.1 * (0.6 + 0.4 * margin)
        return Prediction(label: best.0, confidence: conf)
    }

    // MARK: fuzzy helpers

    /// 1 inside [lo, hi], falls linearly to 0 over `soft` outside.
    private static func inRange(_ v: Double, _ lo: Double, _ hi: Double, soft: Double = 0.15) -> Double {
        if v >= lo && v <= hi { return 1 }
        if v < lo { return clamp(1 - (lo - v) / soft) }
        return clamp(1 - (v - hi) / soft)
    }
    private static func above(_ v: Double, _ t: Double, soft: Double = 0.2) -> Double { clamp((v - t) / soft + 1) }
    private static func below(_ v: Double, _ t: Double, soft: Double = 0.2) -> Double { clamp((t - v) / soft + 1) }

    private static func ext(_ fi: Finger) -> (HandFeatures) -> Double { { above($0.fingerExtension(fi), 0.75) } }
    private static func curl(_ fi: Finger) -> (HandFeatures) -> Double { { below($0.fingerExtension(fi), 0.35) } }
    private static func half(_ fi: Finger) -> (HandFeatures) -> Double { { inRange($0.fingerExtension(fi), 0.3, 0.7, soft: 0.2) } }
    private static let thumbTucked: (HandFeatures) -> Double = { below($0.thumbExtension, 0.4) }
    private static let thumbOut: (HandFeatures) -> Double = { above($0.thumbExtension, 0.7) }
    private static let up: (HandFeatures) -> Double = { above($0.upness, 0.5, soft: 0.3) }
    private static let down: (HandFeatures) -> Double = { below($0.upness, -0.4, soft: 0.3) }
    private static let side: (HandFeatures) -> Double = { above($0.sideways, 0.65, soft: 0.3) }
    private static func together(_ a: Finger, _ b: Finger) -> (HandFeatures) -> Double { { below($0.spread(a, b), 0.3) } }
    private static func apart(_ a: Finger, _ b: Finger) -> (HandFeatures) -> Double { { above($0.spread(a, b), 0.4) } }

    /// Thumb tip x relative to the MCP "columns" (index ≈ +0.3, little ≈ -0.5 in palm units).
    private static func thumbBetween(_ a: Joint, _ b: Joint) -> (HandFeatures) -> Double {
        { f in
            let lo = Double(min(f[a].x, f[b].x)) - 0.08
            let hi = Double(max(f[a].x, f[b].x)) + 0.08
            return inRange(Double(f[.thumbTip].x), lo, hi, soft: 0.15)
        }
    }

    private static func buildRules() -> [Rule] {
        let allCurled: [(Double, (HandFeatures) -> Double)] = [
            (1, curl(.index)), (1, curl(.middle)), (1, curl(.ring)), (1, curl(.little)),
        ]
        func fist(_ label: String, _ extra: [(Double, (HandFeatures) -> Double)]) -> Rule {
            Rule(label: label, conditions: (allCurled + extra).map { (weight: $0.0, value: $0.1) })
        }
        func rule(_ label: String, _ c: [(Double, (HandFeatures) -> Double)]) -> Rule {
            Rule(label: label, conditions: c.map { (weight: $0.0, value: $0.1) })
        }

        var out: [Rule] = []
        // A: fist, thumb straight alongside the index finger (outside, +x).
        out.append(fist("A", [
            (2, { f in above(Double(f[.thumbTip].x) - Double(f[.indexMCP].x), 0.15, soft: 0.15) }),
            (1, { f in inRange(Double(f[.thumbTip].y), 0.7, 1.6, soft: 0.3) }),
            (1, { f in inRange(f.thumbExtension, 0.35, 0.8, soft: 0.2) }),
        ]))
        // S: fist, thumb bent across the front of index/middle.
        out.append(fist("S", [
            (2, thumbBetween(.middleMCP, .indexMCP)),
            (1, { f in inRange(Double(f[.thumbTip].y), 0.75, 1.25, soft: 0.25) }),
            (1, thumbTucked),
        ]))
        // E: fingers curled down onto the thumb, thumb tucked low under the fingertips.
        out.append(fist("E", [
            (2, { f in below(Double(f[.thumbTip].y), 0.9, soft: 0.25) }),
            (1, thumbBetween(.ringMCP, .indexMCP)),
            (1, { f in below(Double(f[.indexTip].y), Double(f[.indexPIP].y), soft: 0.2) }),
        ]))
        // T: thumb pokes up between index and middle.
        out.append(fist("T", [
            (2, thumbBetween(.middleMCP, .indexMCP)),
            (1.5, { f in inRange(Double(f[.thumbTip].y), 1.2, 1.8, soft: 0.25) }),
        ]))
        // N: thumb between middle and ring.
        out.append(fist("N", [
            (2, thumbBetween(.ringMCP, .middleMCP)),
            (1, { f in inRange(Double(f[.thumbTip].y), 1.0, 1.7, soft: 0.3) }),
        ]))
        // M: thumb between ring and little.
        out.append(fist("M", [
            (2, thumbBetween(.littleMCP, .ringMCP)),
            (1, { f in inRange(Double(f[.thumbTip].y), 1.0, 1.7, soft: 0.3) }),
        ]))
        // B: flat hand, fingers together, thumb folded across the palm.
        out.append(rule("B", [
            (1, ext(.index)), (1, ext(.middle)), (1, ext(.ring)), (1, ext(.little)),
            (1, together(.index, .middle)), (1, together(.middle, .ring)), (0.5, together(.ring, .little)),
            (1.5, thumbTucked),
        ]))
        // C: everything half-curled into an open arc.
        out.append(rule("C", [
            (1, half(.index)), (1, half(.middle)), (1, half(.ring)), (1, half(.little)),
            (1, { f in inRange(f.thumbExtension, 0.35, 0.85, soft: 0.2) }),
            (2, { f in inRange(f.dist(.thumbTip, .indexTip), 0.45, 1.2, soft: 0.2) }),
        ]))
        // O: like C but closed – thumb tip touching index tip.
        out.append(rule("O", [
            (1, half(.index)), (1, half(.middle)), (1, half(.ring)), (1, half(.little)),
            (2.5, { f in below(f.dist(.thumbTip, .indexTip), 0.3, soft: 0.2) }),
        ]))
        // D: index up, other fingers curled onto the thumb.
        out.append(rule("D", [
            (2, ext(.index)), (1, curl(.middle)), (1, curl(.ring)), (1, curl(.little)),
            (1.5, { f in below(f.dist(.thumbTip, .middleTip), 0.4, soft: 0.25) }),
            (0.5, up),
        ]))
        // F: index + thumb pinch, three fingers up.
        out.append(rule("F", [
            (2, { f in below(f.dist(.thumbTip, .indexTip), 0.3, soft: 0.2) }),
            (1, { f in below(f.fingerExtension(.index), 0.6, soft: 0.2) }),
            (1, ext(.middle)), (1, ext(.ring)), (1, ext(.little)),
        ]))
        // G: index + thumb extended, hand sideways.
        out.append(rule("G", [
            (1.5, ext(.index)), (1, curl(.middle)), (1, curl(.ring)), (1, curl(.little)),
            (1.5, thumbOut), (2, side),
        ]))
        // H: index + middle together, hand sideways.
        out.append(rule("H", [
            (1, ext(.index)), (1, ext(.middle)), (1, curl(.ring)), (1, curl(.little)),
            (1.5, together(.index, .middle)), (2, side), (0.5, thumbTucked),
        ]))
        // I: little finger up.
        out.append(rule("I", [
            (1, curl(.index)), (1, curl(.middle)), (1, curl(.ring)), (2, ext(.little)),
            (1.5, thumbTucked),
        ]))
        // K: index + middle apart, thumb up between them touching the middle finger.
        out.append(rule("K", [
            (1, ext(.index)), (1, ext(.middle)), (1, curl(.ring)), (1, curl(.little)),
            (1, apart(.index, .middle)),
            (2, { f in below(f.dist(.thumbTip, .middlePIP), 0.4, soft: 0.25) }),
            (1, { f in above(Double(f[.thumbTip].y), 1.0, soft: 0.3) }),
            (1, up),
        ]))
        // L: index up, thumb out at a right angle.
        out.append(rule("L", [
            (1.5, ext(.index)), (1, curl(.middle)), (1, curl(.ring)), (1, curl(.little)),
            (2, thumbOut),
            (1.5, { f in above(Double(f[.thumbTip].x) - Double(f[.indexMCP].x), 0.5, soft: 0.3) }),
            (0.5, up),
        ]))
        // P: K pointing down.
        out.append(rule("P", [
            (1, ext(.index)), (1, ext(.middle)), (1, curl(.ring)), (1, curl(.little)),
            (1, { f in below(f.dist(.thumbTip, .middlePIP), 0.45, soft: 0.25) }),
            (2.5, down),
        ]))
        // Q: G pointing down.
        out.append(rule("Q", [
            (1.5, ext(.index)), (1, curl(.middle)), (1, curl(.ring)), (1, curl(.little)),
            (1.5, thumbOut), (2.5, down),
        ]))
        // R: index and middle crossed.
        out.append(rule("R", [
            (1, ext(.index)), (1, ext(.middle)), (1, curl(.ring)), (1, curl(.little)),
            (1, together(.index, .middle)),
            (2.5, { f in above(Double(f[.middleTip].x) - Double(f[.indexTip].x), 0.05, soft: 0.1) }),
            (0.5, thumbTucked),
        ]))
        // U: index + middle together, pointing up.
        out.append(rule("U", [
            (1, ext(.index)), (1, ext(.middle)), (1, curl(.ring)), (1, curl(.little)),
            (1.5, together(.index, .middle)), (1.5, up), (1, thumbTucked),
            (1, { f in below(Double(f[.middleTip].x) - Double(f[.indexTip].x), 0.0, soft: 0.1) }),
        ]))
        // V: index + middle apart, thumb tucked.
        out.append(rule("V", [
            (1, ext(.index)), (1, ext(.middle)), (1, curl(.ring)), (1, curl(.little)),
            (1.5, apart(.index, .middle)), (1, up),
            (1.5, { f in above(f.dist(.thumbTip, .middlePIP), 0.45, soft: 0.25) }),
        ]))
        // W: three fingers up, little curled.
        out.append(rule("W", [
            (1, ext(.index)), (1, ext(.middle)), (1, ext(.ring)), (2, curl(.little)),
            (1, thumbTucked),
        ]))
        // X: index hooked, everything else curled.
        out.append(rule("X", [
            (2.5, { f in inRange(f.fingerExtension(.index), 0.3, 0.65, soft: 0.15) }),
            (1, curl(.middle)), (1, curl(.ring)), (1, curl(.little)),
            (1, thumbTucked),
        ]))
        // Y: thumb and little finger out.
        out.append(rule("Y", [
            (1, curl(.index)), (1, curl(.middle)), (1, curl(.ring)), (2, ext(.little)),
            (2, thumbOut),
        ]))
        return out
    }
}

// MARK: - kNN on user-taught samples ("teach mode")

final class KNNClassifier: SignClassifier {
    private(set) var samples: [String: [[Float]]] = [:]
    var k = 5
    /// Nearest-neighbour distance beyond which the kNN abstains.
    var maxDistance: Float = 1.3
    private let lock = NSLock()

    var sampleCounts: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return samples.mapValues { $0.count }
    }
    var isEmpty: Bool { sampleCounts.values.reduce(0, +) == 0 }

    func add(label: String, vector: [Float]) {
        lock.lock(); defer { lock.unlock() }
        samples[label, default: []].append(vector)
    }

    func clear(label: String) {
        lock.lock(); defer { lock.unlock() }
        samples[label] = nil
    }

    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        samples = [:]
    }

    func scores(_ f: HandFeatures) -> [(String, Double)] {
        lock.lock(); defer { lock.unlock() }
        var out: [(String, Double)] = []
        for (label, vecs) in samples {
            var best = Float.greatestFiniteMagnitude
            for v in vecs { best = min(best, Self.distance(v, f.vector)) }
            out.append((label, Double(clamp(Double(1 - best / maxDistance)))))
        }
        return out.sorted { $0.1 > $1.1 }
    }

    func classify(_ f: HandFeatures) -> Prediction? {
        lock.lock(); defer { lock.unlock() }
        var neighbours: [(String, Float)] = []
        for (label, vecs) in samples {
            for v in vecs { neighbours.append((label, Self.distance(v, f.vector))) }
        }
        guard !neighbours.isEmpty else { return nil }
        neighbours.sort { $0.1 < $1.1 }
        let nearest = neighbours.prefix(k)
        guard let first = nearest.first, first.1 <= maxDistance else { return nil }

        var votes: [String: Float] = [:]
        var total: Float = 0
        for (label, d) in nearest {
            let w = 1 / (d + 0.05)
            votes[label, default: 0] += w
            total += w
        }
        guard let winner = votes.max(by: { $0.value < $1.value }) else { return nil }
        let share = Double(winner.value / total)
        let closeness = Double(clamp(Double(1 - first.1 / maxDistance)))
        return Prediction(label: winner.key, confidence: share * (0.5 + 0.5 * closeness))
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
        return dir.appendingPathComponent("templates.json")
    }

    static func loadFromDisk() -> KNNClassifier {
        let c = KNNClassifier()
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode([String: [[Float]]].self, from: data) {
            c.samples = decoded
        }
        return c
    }

    func save() {
        lock.lock()
        let snapshot = samples
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.storageURL, options: .atomic)
        }
    }
}

// MARK: - Ensemble: taught samples first, rules as the fallback

final class EnsembleClassifier: SignClassifier {
    let knn: KNNClassifier
    let rules: RuleClassifier

    init(knn: KNNClassifier, rules: RuleClassifier) {
        self.knn = knn
        self.rules = rules
    }

    func classify(_ f: HandFeatures) -> Prediction? {
        if let p = knn.classify(f), p.confidence >= 0.5 { return p }
        return rules.classify(f)
    }

    func scores(_ f: HandFeatures) -> [(String, Double)] {
        rules.scores(f)
    }
}
