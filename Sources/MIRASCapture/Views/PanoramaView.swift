import SwiftUI
import SceneKit
import CoreMotion
import Geometry
import simd

@MainActor final class PanoramaController: NSObject, ObservableObject {
    @Published var look = SphericalAngle(yaw: 0, pitch: 0)
    @Published var fieldOfView = 70.0
    @Published var gyro = false { didSet { gyro ? startMotion() : motion.stopDeviceMotionUpdates() } }
    let motion = CMMotionManager()
    let camera = SCNNode()
    let scene = SCNScene()
    @Published var error: String?
    private var motionOrigin: (yaw:Double,pitch:Double)?
    private var lookOrigin = SphericalAngle(yaw: 0,pitch:0)
    var onTap: ((SphericalAngle) -> Void)?
    var onMove: ((String, SphericalAngle) -> Void)?
    private var previous = CGPoint.zero
    private var draggingID: String?
    private var pinchFOV = 70.0
    override init() {
        super.init(); camera.camera = SCNCamera(); camera.camera?.zNear = 0.01; camera.camera?.zFar = 10; scene.rootNode.addChildNode(camera)
    }
    func load(image: CGImage) {
        guard scene.rootNode.childNode(withName: "panorama", recursively: false) == nil else { return }
        let sphere = PanoramaMesh.make()
        let material = SCNMaterial(); material.diffuse.contents = image; material.lightingModel = .constant; material.isDoubleSided = false
        material.diffuse.wrapS = .repeat
        // Trilinear, anisotropic sampling keeps zoomed-out and steep views free of shimmer and blur.
        material.diffuse.mipFilter = .linear; material.diffuse.maxAnisotropy = 16
        sphere.firstMaterial = material
        let node = SCNNode(geometry: sphere); node.name = "panorama"; scene.rootNode.addChildNode(node)
        updateCamera()
    }
    func updateCamera() {
        look.pitch = min(85,max(-85,look.pitch)); camera.eulerAngles = .init(Float(look.pitch * .pi/180), Float(-look.yaw * .pi/180),0)
        camera.camera?.projectionDirection = .vertical; camera.camera?.fieldOfView = fieldOfView
    }
    func updateHotspots(_ spots: [Hotspot]) {
        scene.rootNode.childNodes.filter { $0.name?.hasPrefix("hotspot:") == true }.forEach { $0.removeFromParentNode() }
        for dot in spots {
            let v = SphericalAngle(yaw:dot.yaw,pitch:dot.pitch).vector
            let halo = SCNSphere(radius:0.045); let mat = SCNMaterial(); mat.diffuse.contents = UIColor.black.withAlphaComponent(0.65); mat.lightingModel = .constant; halo.firstMaterial = mat
            let node = SCNNode(geometry:halo); node.position = .init(Float(v.x)*2,Float(v.y)*2,Float(v.z)*2); node.name = "hotspot:\(dot.id)"
            let center = SCNNode(geometry:SCNSphere(radius:0.026)); center.geometry?.firstMaterial?.diffuse.contents = UIColor.white; center.geometry?.firstMaterial?.lightingModel = .constant; center.name = node.name
            let length = sqrt(node.position.x*node.position.x+node.position.y*node.position.y+node.position.z*node.position.z)
            center.position = .init(-node.position.x/length*0.03,-node.position.y/length*0.03,-node.position.z/length*0.03)
            node.addChildNode(center); scene.rootNode.addChildNode(node)
        }
    }
    func ray(_ point: CGPoint, in view: UIView) -> SphericalAngle { Geometry.tapRay(x:point.x,y:point.y,width:view.bounds.width,height:view.bounds.height,verticalFOV:fieldOfView,look:look) }
    @objc func tap(_ g: UITapGestureRecognizer) { guard let view = g.view else { return }; onTap?(ray(g.location(in:view),in:view)) }
    @objc func pan(_ g: UIPanGestureRecognizer) {
        guard let view = g.view as? SCNView else { return }
        let p = g.location(in:view)
        if g.state == .began {
            previous = p
            draggingID = view.hitTest(p,options:nil).first(where: { $0.node.name?.hasPrefix("hotspot:") == true })?.node.name.map { String($0.dropFirst(8)) }
        } else if g.state == .changed {
            if let id = draggingID { onMove?(id,ray(p,in:view)) }
            else { gyro = false; look.yaw -= Double(p.x-previous.x)*fieldOfView/Double(view.bounds.height); look.pitch += Double(p.y-previous.y)*fieldOfView/Double(view.bounds.height); updateCamera() }
            previous = p
        } else { draggingID = nil }
    }
    @objc func pinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { pinchFOV = fieldOfView }
        fieldOfView = min(100,max(40,pinchFOV/Double(g.scale))); updateCamera()
    }
    func startMotion() {
        guard motion.isDeviceMotionAvailable else { gyro = false; error = "Gyroscope viewing is unavailable here. Drag the panorama to look around."; return }
        motionOrigin = nil; lookOrigin = look; motion.deviceMotionUpdateInterval = 1/60
        motion.startDeviceMotionUpdates(using:.xArbitraryZVertical,to:.main) { [weak self] value, error in
            guard let self else { return }
            if let error { self.gyro = false; self.error = "Motion tracking stopped: \(error.localizedDescription). Toggle Gyro to retry or drag to look around."; return }
            guard let value else { return }
            let a = value.attitude.quaternion
            let q = simd_quatd(ix:a.x,iy:a.y,iz:a.z,r:a.w)
            let forward = q.act(SIMD3<Double>(0,0,-1))
            let yaw = atan2(-forward.y,forward.x), pitch = asin(min(1,max(-1,forward.z)))
            if self.motionOrigin == nil { self.motionOrigin = (yaw,pitch) }
            guard let origin = self.motionOrigin else { return }
            let delta = atan2(sin(yaw-origin.yaw),cos(yaw-origin.yaw))
            self.look = .init(yaw:self.lookOrigin.yaw+delta*180 / .pi,pitch:self.lookOrigin.pitch+(pitch-origin.pitch)*180 / .pi); self.updateCamera()
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
}
struct PanoramaView: UIViewRepresentable {
    let image: CGImage; let hotspots: [Hotspot]; let controller: PanoramaController
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(); view.backgroundColor = .black; view.scene = controller.scene; view.pointOfView = controller.camera
        view.addGestureRecognizer(UITapGestureRecognizer(target:controller,action:#selector(PanoramaController.tap(_:))))
        view.addGestureRecognizer(UIPanGestureRecognizer(target:controller,action:#selector(PanoramaController.pan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target:controller,action:#selector(PanoramaController.pinch(_:))))
        view.accessibilityLabel = "360 degree panorama. Drag to look around. Tap to add a hotspot."
        controller.load(image:image); return view
    }
    func updateUIView(_ view: SCNView, context: Context) { controller.updateHotspots(hotspots) }
    static func dismantleUIView(_ view: SCNView, coordinator: ()) { view.isPlaying = false }
}
