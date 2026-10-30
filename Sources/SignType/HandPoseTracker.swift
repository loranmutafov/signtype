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

struct HandPose {
    /// 21 points in Vision's normalized image space (origin bottom-left, un-mirrored camera frame).
    var points: [CGPoint]
    var confidences: [Float]
    var isLeft: Bool
}

/// Runs Apple's on-device hand pose model. Works on any Apple Silicon or Intel Mac on macOS 11+.
final class HandPoseTracker {
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()

    func detect(in pixelBuffer: CVPixelBuffer) -> HandPose? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let obs = request.results?.first,
              let all = try? obs.recognizedPoints(.all) else { return nil }

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

        return HandPose(points: points, confidences: conf, isLeft: obs.chirality == .left)
    }
}
