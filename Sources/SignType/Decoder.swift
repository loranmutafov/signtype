import Foundation

enum DecodeEvent: Equatable {
    case letter(String)
    case space
}

/// Turns a noisy per-frame stream of predictions into discrete letters.
///  * a letter is emitted once it has been the top prediction for `stableFrames` in a row
///  * the same letter is not emitted again until something else (or no hand) was seen
///    for `repeatGapFrames` – so doubled letters are signed as letter, pause, letter
///  * `spaceAfterNoHandFrames` of no hand emits a single space
final class Decoder {
    var stableFrames = 6
    var minConfidence = 0.55
    var spaceAfterNoHandFrames = 18
    var repeatGapFrames = 4

    private var current: String?
    private var currentCount = 0
    private var lastEmitted: String?
    private var gap = 0
    private var noHandFrames = 0
    private var spaceEmitted = true

    /// Frames in a row the current top label has been held. Exposed for the overlay's progress ring.
    var holdProgress: Double {
        guard current != nil else { return 0 }
        return min(1, Double(currentCount) / Double(stableFrames))
    }

    func reset() {
        current = nil
        currentCount = 0
        lastEmitted = nil
        gap = 0
        noHandFrames = 0
        spaceEmitted = true
    }

    /// The hand is moving (a whole-word sign in progress): forget any half-held letter but
    /// do not count this as "no hand" for the space logic.
    func pause() {
        current = nil
        currentCount = 0
        noHandFrames = 0
    }

    /// Something else (a word) was just emitted with its own trailing space.
    func markExternalOutput() {
        current = nil
        currentCount = 0
        lastEmitted = nil
        gap = 0
        noHandFrames = 0
        spaceEmitted = true
    }

    func ingest(_ p: Prediction?) -> DecodeEvent? {
        let label: String? = {
            guard let p, p.confidence >= minConfidence else { return nil }
            return p.label
        }()

        guard let label else {
            noHandFrames += 1
            current = nil
            currentCount = 0
            gap += 1
            if p == nil, noHandFrames == spaceAfterNoHandFrames, lastEmitted != nil, !spaceEmitted {
                spaceEmitted = true
                return .space
            }
            return nil
        }

        noHandFrames = 0
        if label == current {
            currentCount += 1
        } else {
            current = label
            currentCount = 1
        }
        if label != lastEmitted { gap += 1 }

        if currentCount == stableFrames, label != lastEmitted || gap >= repeatGapFrames {
            lastEmitted = label
            gap = 0
            spaceEmitted = false
            return .letter(label)
        }
        return nil
    }
}
