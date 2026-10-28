import SceneKit
import Geometry

// Explicit MIRAS longitude/latitude UVs avoid SceneKit sphere seam and handedness assumptions.
enum PanoramaMesh {
    static func make(radius: Float = 5) -> SCNGeometry {
        let columns = 128, rows = 64
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], uv: [CGPoint] = [], indices: [Int32] = []
        for row in 0...rows { for col in 0...columns {
            let u = Double(col)/Double(columns), v = Double(row)/Double(rows)
            let d = SphericalAngle(u:u,v:v).vector
            vertices.append(.init(Float(d.x)*radius,Float(d.y)*radius,Float(d.z)*radius))
            normals.append(.init(-Float(d.x),-Float(d.y),-Float(d.z)))
            uv.append(CGPoint(x:u,y:v))
        } }
        for row in 0..<rows { for col in 0..<columns {
            let a = Int32(row*(columns+1)+col), b = a+1, c = a+Int32(columns+1), d = c+1
            indices.append(contentsOf:[a,c,b,b,c,d])
        } }
        return SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(normals:normals),SCNGeometrySource(textureCoordinates:uv)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
    }
}
