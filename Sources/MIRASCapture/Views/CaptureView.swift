import SwiftUI
import ARKit
import Geometry

struct CameraView: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView { let view = ARSCNView(); view.session = session; view.automaticallyUpdatesLighting = false; return view }
    func updateUIView(_ uiView: ARSCNView, context: Context) { }
}
struct CaptureView: View {
    @State private var model = CaptureViewModel()
    @Environment(\.dismiss) private var dismiss
    var finished: (CaptureDocument) -> Void
    private func guidance(size:CGSize) -> (point:CGPoint,rotation:Double)? {
        guard let target = model.target, let frame = model.service.session.currentFrame else { return nil }
        let angle = SphericalAngle(yaw:target.angle.yaw+model.document.referenceWorldYaw,pitch:target.angle.pitch)
        let d = angle.vector, origin = frame.camera.transform.columns.3
        let point = SIMD3(origin.x+Float(d.x)*1.5,origin.y+Float(d.y)*1.5,origin.z+Float(d.z)*1.5)
        let local = frame.camera.viewMatrix(for:.portrait)*SIMD4(point,1)
        let screen = frame.camera.projectPoint(point,orientation:.portrait,viewportSize:size)
        if local.z < 0 && screen.x > 24 && screen.x < size.width-24 && screen.y > 100 && screen.y < size.height-120 { return nil }
        var dx = screen.x-size.width/2, dy = screen.y-size.height/2
        if local.z >= 0 { dx = -dx; dy = -dy }
        if abs(dx)+abs(dy) < 0.01 { dy = 1 }
        let scale = min((size.width/2-28)/max(0.01,abs(dx)),(size.height/2-120)/max(0.01,abs(dy)))
        return (CGPoint(x:size.width/2+dx*scale,y:size.height/2+dy*scale),atan2(Double(dx),Double(-dy))*180 / .pi)
    }
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                CameraView(session: model.service.session).ignoresSafeArea()
                Canvas { context, size in
                    guard let sample = model.sample else { return }
                    // Use ARKit's portrait projection, including the sensor's actual roll.
                    let orientation = UIInterfaceOrientation.portrait
                    for dot in model.document.targets {
                        let angle = SphericalAngle(yaw: dot.angle.yaw+model.document.referenceWorldYaw, pitch: dot.angle.pitch)
                        let v = angle.vector, p = sample.transform.columns.3
                        let point = SIMD3<Float>(p.x+Float(v.x)*1.5,p.y+Float(v.y)*1.5,p.z+Float(v.z)*1.5)
                        guard let frame = model.service.session.currentFrame else { continue }
                        let cameraDirection = simd_inverse(frame.camera.transform)*SIMD4(point, 1)
                        guard cameraDirection.z < 0 else { continue }
                        let projected = frame.camera.projectPoint(point, orientation: orientation, viewportSize: size)
                        let done = model.completed.contains(dot.id), next = dot.id == model.target?.id
                        let radius: CGFloat = done ? 5 : next ? 13+CGFloat(sin(sample.timestamp*5))*2 : 8
                        let rect = CGRect(x: projected.x-radius,y: projected.y-radius,width: radius*2,height: radius*2)
                        context.fill(Path(ellipseIn: rect), with: .color(done ? .green : .white))
                    }
                }.allowsHitTesting(false)
                Circle().trim(from: 0, to: model.alignment).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90)).frame(width: 56, height: 56)
                Circle().stroke(.white.opacity(0.7), lineWidth: 1).frame(width: 56,height:56)
                if let guide = guidance(size:proxy.size) {
                    Image(systemName:"arrow.up").font(.largeTitle.bold()).rotationEffect(.degrees(guide.rotation)).position(guide.point).accessibilityLabel("Turn toward the next target")
                }
                VStack(spacing: 20) {
                    HStack {
                        Button("Close", systemImage: "xmark") { model.stop(); dismiss() }.labelStyle(.iconOnly)
                        Spacer(); Text("\(model.document.frames.count) / \(model.document.targets.count)").monospacedDigit(); Spacer()
                        Button("Finish") { model.stop(); finished(model.document); dismiss() }.disabled(!model.canFinish || model.busy)
                    }.padding().background(.ultraThinMaterial, in: Capsule())
                    Text(model.coaching).font(.headline).padding().background(.ultraThinMaterial,in: Capsule()).accessibilityAddTraits(.updatesFrequently)
                    Spacer()
                    HStack {
                        Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }.disabled(model.document.frames.isEmpty || model.busy)
                        Spacer()
                        SphereMinimap(targets: model.document.targets, completed: model.completed).frame(width: 88,height:88).accessibilityLabel("Capture coverage, \(model.document.frames.count) shots completed")
                    }.padding().background(.ultraThinMaterial,in: RoundedRectangle(cornerRadius:20))
                }.padding()
                if model.flash { Color.white.opacity(0.65).ignoresSafeArea().allowsHitTesting(false) }
            }
        }.task { await model.start() }.onDisappear { model.stop() }
        .alert("Capture needs attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Retry") { if !model.started { Task { await model.start() } } }
            Button("Close", role: .cancel) { dismiss() }
        } message: { Text(model.error ?? "") }
    }
}
struct SphereMinimap: View {
    let targets: [ShotTarget]; let completed: Set<Int>
    var body: some View {
        Canvas { context, size in
            context.stroke(Path(ellipseIn: CGRect(origin:.zero,size:size)),with:.color(.white.opacity(0.3)),lineWidth:1)
            for dot in targets {
                let v = dot.angle.vector
                let x = size.width/2+CGFloat(v.x)*size.width*0.43, y = size.height/2-CGFloat(v.y)*size.height*0.43
                context.fill(Path(ellipseIn: CGRect(x:x-2,y:y-2,width:4,height:4)),with:.color(completed.contains(dot.id) ? .green : .white.opacity(v.z < 0 ? 0.9 : 0.3)))
            }
        }
    }
}
