import CoreGraphics
import Vision

/// Index into the 21-point hand skeleton. Matches MediaPipe ordering so
/// templates/notes from other projects translate directly.
enum Joint: Int, CaseIterable {
    case wrist = 0
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip

    var visionName: VNHumanHandPoseObservation.JointName {
        switch self {
        case .wrist: return .wrist
        case .thumbCMC: return .thumbCMC
        case .thumbMP: return .thumbMP
        case .thumbIP: return .thumbIP
        case .thumbTip: return .thumbTip
        case .indexMCP: return .indexMCP
        case .indexPIP: return .indexPIP
        case .indexDIP: return .indexDIP
        case .indexTip: return .indexTip
        case .middleMCP: return .middleMCP
        case .middlePIP: return .middlePIP
        case .middleDIP: return .middleDIP
        case .middleTip: return .middleTip
        case .ringMCP: return .ringMCP
        case .ringPIP: return .ringPIP
        case .ringDIP: return .ringDIP
        case .ringTip: return .ringTip
        case .littleMCP: return .littleMCP
        case .littlePIP: return .littlePIP
        case .littleDIP: return .littleDIP
        case .littleTip: return .littleTip
        }
    }

    /// Bones to draw in the overlay.
    static let bones: [(Joint, Joint)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP),
    ]
}

/// Upper-body joints we keep from Vision's body-pose model.
enum BodyJoint: Int, CaseIterable {
    case nose = 0
    case leftEye, rightEye, leftEar, rightEar
    case neck, leftShoulder, rightShoulder
    case leftElbow, rightElbow, leftWrist, rightWrist

    var visionName: VNHumanBodyPoseObservation.JointName {
        switch self {
        case .nose: return .nose
        case .leftEye: return .leftEye
        case .rightEye: return .rightEye
        case .leftEar: return .leftEar
        case .rightEar: return .rightEar
        case .neck: return .neck
        case .leftShoulder: return .leftShoulder
        case .rightShoulder: return .rightShoulder
        case .leftElbow: return .leftElbow
        case .rightElbow: return .rightElbow
        case .leftWrist: return .leftWrist
        case .rightWrist: return .rightWrist
        }
    }

    static let bones: [(BodyJoint, BodyJoint)] = [
        (.nose, .leftEye), (.nose, .rightEye), (.leftEye, .leftEar), (.rightEye, .rightEar),
        (.nose, .neck), (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
    ]
}

struct HandPose {
    /// 21 points in Vision's normalized image space (origin bottom-left, un-mirrored camera frame).
    var points: [CGPoint]
    var confidences: [Float]
    var isLeft: Bool
    var chiralityKnown: Bool
    /// Mean confidence, used to pick the primary hand for fingerspelling.
    var quality: Float { confidences.reduce(0, +) / Float(max(confidences.count, 1)) }
}

struct BodyPose {
    var points: [CGPoint]
    var confidences: [Float]

    func point(_ j: BodyJoint, minConfidence: Float = 0.2) -> CGPoint? {
        confidences[j.rawValue] >= minConfidence ? points[j.rawValue] : nil
    }

    /// Compact confidence readout for logs: nose / left shoulder / right shoulder.
    var summary: String {
        let n = confidences[BodyJoint.nose.rawValue]
        let l = confidences[BodyJoint.leftShoulder.rawValue]
        let r = confidences[BodyJoint.rightShoulder.rawValue]
        return String(format: "nose %.2f lsh %.2f rsh %.2f", n, l, r)
    }
}

/// Everything we extract from one camera frame.
struct FrameObservation {
    var hands: [HandPose]
    var body: BodyPose?

    /// Best hand for fingerspelling: highest tracking quality.
    var primaryHand: HandPose? { hands.max { $0.quality < $1.quality } }
}

/// Runs Apple's on-device hand-pose and body-pose models on each frame.
/// Works on any Apple Silicon or Intel Mac on macOS 11+.
final class PoseTracker {
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    private let bodyRequest = VNDetectHumanBodyPoseRequest()

    /// Shoulders and face move slowly; run the body model on every Nth frame and reuse the
    /// last result in between. Keeps the per-frame cost close to hands-only.
    var bodyEvery = 3
    private var frameIndex = 0
    private var cachedBody: BodyPose?

    func detect(in pixelBuffer: CVPixelBuffer) -> FrameObservation {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        let runBody = frameIndex % max(bodyEvery, 1) == 0
        frameIndex &+= 1
        do {
            try handler.perform(runBody ? [handRequest, bodyRequest] : [handRequest])
        } catch {
            return FrameObservation(hands: [], body: cachedBody)
        }

        var hands: [HandPose] = []
        for obs in handRequest.results ?? [] {
            if let hand = Self.hand(from: obs) { hands.append(hand) }
        }
        if runBody {
            cachedBody = (bodyRequest.results ?? []).first.flatMap(Self.body(from:))
        }
        return FrameObservation(hands: hands, body: cachedBody)
    }

    private static func hand(from obs: VNHumanHandPoseObservation) -> HandPose? {
        guard let all = try? obs.recognizedPoints(.all) else { return nil }
        var points = [CGPoint](repeating: .zero, count: Joint.allCases.count)
        var conf = [Float](repeating: 0, count: Joint.allCases.count)
        for joint in Joint.allCases {
            if let p = all[joint.visionName] {
                points[joint.rawValue] = p.location
                conf[joint.rawValue] = p.confidence
            }
        }
        // Require a believable wrist + at least a few confident fingertips.
        guard conf[Joint.wrist.rawValue] > 0.3, conf[Joint.middleMCP.rawValue] > 0.3 else { return nil }
        let tipConf = [Joint.indexTip, .middleTip, .ringTip, .littleTip, .thumbTip].map { conf[$0.rawValue] }
        guard tipConf.filter({ $0 > 0.3 }).count >= 3 else { return nil }

        return HandPose(
            points: points,
            confidences: conf,
            isLeft: obs.chirality == .left,
            chiralityKnown: obs.chirality != .unknown
        )
    }

    private static func body(from obs: VNHumanBodyPoseObservation) -> BodyPose? {
        guard let all = try? obs.recognizedPoints(.all) else { return nil }
        var points = [CGPoint](repeating: .zero, count: BodyJoint.allCases.count)
        var conf = [Float](repeating: 0, count: BodyJoint.allCases.count)
        for joint in BodyJoint.allCases {
            if let p = all[joint.visionName] {
                points[joint.rawValue] = p.location
                conf[joint.rawValue] = p.confidence
            }
        }
        // Vision reports low-ish confidences for partially visible upper bodies; be lenient and
        // let consumers pick their own threshold.
        guard conf.max() ?? 0 > 0.1 else { return nil }
        return BodyPose(points: points, confidences: conf)
    }
}
