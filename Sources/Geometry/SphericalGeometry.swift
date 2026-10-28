import Foundation

public struct Vector3: Codable, Equatable, Sendable {
    public var x: Double; public var y: Double; public var z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public func dot(_ b: Self) -> Double { x*b.x + y*b.y + z*b.z }
    public var length: Double { sqrt(dot(self)) }
    public var normalized: Self { let n = max(length, 1e-12); return .init(x/n, y/n, z/n) }
}
public struct SphericalAngle: Codable, Equatable, Sendable {
    public var yaw: Double; public var pitch: Double
    public init(yaw: Double, pitch: Double) { self.yaw = yaw; self.pitch = pitch }
    public var vector: Vector3 {
        let y = yaw * .pi / 180, p = pitch * .pi / 180
        return .init(sin(y)*cos(p), sin(p), -cos(y)*cos(p))
    }
    public init(vector: Vector3) {
        let v = vector.normalized
        yaw = atan2(v.x, -v.z) * 180 / .pi
        pitch = asin(min(1, max(-1, v.y))) * 180 / .pi
    }
    public var uv: (u: Double, v: Double) { (Geometry.wrap(0.5 + yaw/360, period: 1), min(1, max(0, 0.5-pitch/180))) }
    public init(u: Double, v: Double) { self.init(yaw: (Geometry.wrap(u, period: 1)-0.5)*360, pitch: 90-min(1, max(0, v))*180) }
    public func distance(to b: Self) -> Double { acos(min(1, max(-1, vector.dot(b.vector)))) * 180 / .pi }
    public func pixel(width: Int, height: Int) -> (x: Double, y: Double) { (uv.u*Double(width), uv.v*Double(height)) }
}
public enum Geometry {
    public static func hasReliableHeading(_ heading: Double?, accuracy: Double?) -> Bool {
        guard let heading, let accuracy else { return false }
        return heading.isFinite && accuracy.isFinite && (0..<360).contains(heading) && (0...15).contains(accuracy)
    }
    public static func wrap(_ value: Double, period: Double = 360) -> Double { (value.truncatingRemainder(dividingBy: period)+period).truncatingRemainder(dividingBy: period) }
    public static func northReference(firstWorldYaw: Double, heading: Double?, accuracy: Double?) -> Double {
        guard hasReliableHeading(heading, accuracy: accuracy), let h = heading else { return firstWorldYaw }
        return firstWorldYaw-h
    }
    public static func tapRay(x: Double, y: Double, width: Double, height: Double, verticalFOV: Double, look: SphericalAngle) -> SphericalAngle {
        let scale = tan(verticalFOV * .pi / 360)
        let rx = (2*x/width-1)*width/height*scale, ry = (1-2*y/height)*scale
        let p = look.pitch * .pi/180, a = look.yaw * .pi/180
        let forward = look.vector
        let right = Vector3(cos(a), 0, sin(a))
        let up = Vector3(-sin(a)*sin(p), cos(p), cos(a)*sin(p))
        return SphericalAngle(vector: .init(forward.x+rx*right.x+ry*up.x, forward.y+rx*right.y+ry*up.y, forward.z+rx*right.z+ry*up.z))
    }
}
public struct ShotTarget: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var angle: SphericalAngle
    public var optional: Bool
    public init(id: Int, angle: SphericalAngle, optional: Bool = false) { self.id = id; self.angle = angle; self.optional = optional }
}
public enum ShotPlanner {
    public static func plan(horizontalFOV: Double, verticalFOV: Double, overlap: Double = 0.3) -> [ShotTarget] {
        // Inscribed circular footprint guarantees coverage regardless of portrait camera roll.
        let fov = min(120, max(10, min(horizontalFOV, verticalFOV)))
        let step = fov * (1-min(0.6, max(0.2, overlap))) * 0.85
        let bands = max(2, Int(ceil(90 / step)))
        let spacing = 90 / Double(bands)
        var result: [ShotTarget] = []
        var pitches: [Double] = [0]
        for band in 1..<bands { pitches.append(Double(band)*spacing); pitches.append(-Double(band)*spacing) }
        pitches.append(contentsOf: [90, -90])
        for pitch in pitches {
            let count = abs(pitch) == 90 ? 1 : max(1, Int(ceil(360*cos(pitch * .pi/180)/step)))
            for i in 0..<count { result.append(.init(id: result.count, angle: .init(yaw: Double(i)*360/Double(count), pitch: pitch), optional: pitch == -90)) }
        }
        return result
    }
    public static func covers(_ direction: SphericalAngle, target: SphericalAngle, horizontalFOV: Double, verticalFOV: Double) -> Bool {
        let yaw = target.yaw * .pi/180, pitch = target.pitch * .pi/180
        let d = direction.vector, f = d.dot(target.vector)
        guard f > 0 else { return false }
        let right = Vector3(cos(yaw), 0, sin(yaw))
        let up = Vector3(-sin(yaw)*sin(pitch), cos(pitch), cos(yaw)*sin(pitch))
        return abs(d.dot(right)/f) <= tan(horizontalFOV * .pi/360) && abs(d.dot(up)/f) <= tan(verticalFOV * .pi/360)
    }
}
