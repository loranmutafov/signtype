import CoreGraphics
import Foundation

enum Finger: Int, CaseIterable {
    case index = 0, middle, ring, little

    var mcp: Joint { [.indexMCP, .middleMCP, .ringMCP, .littleMCP][rawValue] }
    var pip: Joint { [.indexPIP, .middlePIP, .ringPIP, .littlePIP][rawValue] }
    var dip: Joint { [.indexDIP, .middleDIP, .ringDIP, .littleDIP][rawValue] }
    var tip: Joint { [.indexTip, .middleTip, .ringTip, .littleTip][rawValue] }
}

/// Hand landmarks normalised into a canonical frame:
///   * wrist at the origin
///   * 1 unit = wrist → middle MCP distance (palm length)
///   * rotated so the palm points up (+y)
///   * mirrored for left hands so the thumb is always on +x
/// `orientation` keeps the hand's real on-screen angle (radians, π/2 = fingers up)
/// because letters like G/H/P/Q depend on it.
struct HandFeatures {
    let canonical: [CGPoint]
    let orientation: Double
    let isLeft: Bool

    /// Flat vector used by the kNN classifier.
    let vector: [Float]

    init(pose: HandPose) {
        let w = pose.points[Joint.wrist.rawValue]
        let m = pose.points[Joint.middleMCP.rawValue]
        let dx = Double(m.x - w.x)
        let dy = Double(m.y - w.y)
        let scale = max((dx * dx + dy * dy).squareRoot(), 1e-4)
        let raw = atan2(dy, dx)
        let rot = Double.pi / 2 - raw
        let c = cos(rot)
        let s = sin(rot)

        var pts: [CGPoint] = []
        pts.reserveCapacity(pose.points.count)
        for p in pose.points {
            let x = Double(p.x - w.x) / scale
            let y = Double(p.y - w.y) / scale
            var rx = x * c - y * s
            let ry = x * s + y * c
            if pose.isLeft { rx = -rx }
            pts.append(CGPoint(x: rx, y: ry))
        }
        canonical = pts
        // Mirror the on-screen orientation for left hands as well.
        orientation = pose.isLeft ? Double.pi - raw : raw
        isLeft = pose.isLeft

        var v: [Float] = []
        v.reserveCapacity(pts.count * 2 + 2)
        for p in pts {
            v.append(Float(p.x))
            v.append(Float(p.y))
        }
        // Orientation gets a modest weight so U vs H etc. separate without dominating.
        v.append(Float(cos(orientation)) * 0.5)
        v.append(Float(sin(orientation)) * 0.5)
        vector = v
    }

    // MARK: Geometry helpers (all in canonical palm units)

    subscript(_ j: Joint) -> CGPoint { canonical[j.rawValue] }

    func dist(_ a: Joint, _ b: Joint) -> Double {
        let p = self[a], q = self[b]
        return Double(hypot(p.x - q.x, p.y - q.y))
    }

    /// Interior angle at `b` formed by a-b-c, in degrees.
    func angle(_ a: Joint, _ b: Joint, _ c: Joint) -> Double {
        let p = self[a], q = self[b], r = self[c]
        let v1 = CGPoint(x: p.x - q.x, y: p.y - q.y)
        let v2 = CGPoint(x: r.x - q.x, y: r.y - q.y)
        let dot = Double(v1.x * v2.x + v1.y * v2.y)
        let mag = max(Double(hypot(v1.x, v1.y) * hypot(v2.x, v2.y)), 1e-6)
        return acos(max(-1, min(1, dot / mag))) * 180 / Double.pi
    }

    /// 0 = fully curled, 1 = fully straight. Blends joint angle with fingertip reach so that
    /// foreshortened fingers (curled towards the camera) still read as curled.
    func fingerExtension(_ f: Finger) -> Double {
        let a = angle(f.mcp, f.pip, f.tip)
        let aScore = clamp((a - 70) / 100)                // 70° → 0, 170° → 1
        let reach = dist(.wrist, f.tip) / max(dist(.wrist, f.mcp), 1e-3)
        let rScore = clamp((reach - 1.05) / 0.8)          // 1.05 → 0, 1.85 → 1
        return 0.5 * (aScore + rScore)
    }

    /// 0 = thumb tucked/bent across the palm, 1 = thumb straight and sticking out.
    var thumbExtension: Double {
        let a = angle(.thumbCMC, .thumbMP, .thumbTip)
        let aScore = clamp((a - 100) / 70)                // 100° → 0, 170° → 1
        let d = dist(.thumbTip, .indexMCP)
        let dScore = clamp((d - 0.35) / 0.6)              // 0.35 → 0, 0.95 → 1
        return 0.5 * (aScore + dScore)
    }

    /// Distance between two fingertips.
    func spread(_ a: Finger, _ b: Finger) -> Double { dist(a.tip, b.tip) }

    /// +1 fingers point up on screen, -1 down, 0 sideways.
    var upness: Double { sin(orientation) }
    /// 1 when the hand points sideways on screen.
    var sideways: Double { abs(cos(orientation)) }
}

@inline(__always) func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double {
    min(hi, max(lo, x))
}
