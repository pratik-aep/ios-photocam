import SwiftUI

struct LibraryView: View {
    @State private var model = LibraryViewModel()
    @State private var showCapture = false
    @State private var showDebug = false
    @State private var deleting: CaptureDocument?
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    var body: some View {
        NavigationStack {
            ZStack {
                Color(white:0.055).ignoresSafeArea()
                VStack(alignment:.leading,spacing:24) {
                    VStack(alignment:.leading,spacing:8) {
                        Text("MIRAS").font(.caption.weight(.semibold)).tracking(5).foregroundStyle(Color.accentColor)
                        Text("Capture a place.\nKeep its story.").font(.largeTitle.weight(.medium))
                        Text("Create immersive 360° heritage photographs.").foregroundStyle(.secondary)
                    }.padding(.horizontal)
                    Button { showCapture = true } label: { Label("New capture",systemImage:"camera.aperture").frame(maxWidth:.infinity).padding(.vertical,10) }.buttonStyle(.borderedProminent).padding(.horizontal)
                    if !model.libraryWarnings.isEmpty {
                        Label("\(model.libraryWarnings.count) capture(s) could not be loaded. Their files are kept for recovery.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).padding(.horizontal)
                    }
                    if model.captures.isEmpty {
                        ContentUnavailableView("Your collection begins here",systemImage:"pano",description:Text("Follow the dots to capture your first place."))
                    } else {
                        List(model.captures) { capture in
                            Button { model.selected = capture } label: {
                                HStack(spacing:16) {
                                    Thumbnail(id:capture.id,stitched:capture.stitched).frame(width:72,height:62).clipShape(RoundedRectangle(cornerRadius:10))
                                    VStack(alignment:.leading,spacing:6) {
                                        Text(capture.name).font(.headline).foregroundStyle(.primary)
                                        Text(capture.place ?? capture.date.formatted(date:.abbreviated,time:.omitted)).font(.caption).foregroundStyle(.secondary)
                                        Text(capture.status).font(.caption).foregroundStyle(Color.accentColor)
                                    }
                                }.padding(.vertical,6)
                            }.swipeActions { Button("Delete",role:.destructive) { deleting = capture } }
                            .contextMenu {
                                Button("Open") { model.selected = capture }
                                Button("Re-stitch") { model.stitch(capture) }.disabled(capture.frames.isEmpty)
                                Button("Export") { model.export(capture) }.disabled(!capture.stitched)
                                Button("Delete",role:.destructive) { deleting = capture }
                            }
                        }.listStyle(.plain)
                    }
                    Spacer(minLength:0)
                }.padding(.top)
                if let value = model.progress {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing:20) { ProgressView(value:value); Text(model.activity); Button("Cancel") { model.work?.cancel() } }.padding(30).background(.regularMaterial,in:RoundedRectangle(cornerRadius:24)).padding(36)
                }
            }.navigationTitle("MIRAS Capture").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.principal) { Text("MIRAS Capture").font(.headline).onLongPressGesture { showDebug = true }.accessibilityAddTraits(.isButton).accessibilityHint("Long press for debug tools") } }
            .task { await model.refresh() }
            .fullScreenCover(isPresented:$showCapture) { CaptureView { c in Task { await model.save(c); model.selected = c } } }
            .sheet(item:$model.selected) { capture in DetailView(document:capture,library:model) }
            .sheet(isPresented:Binding(get:{ !onboardingComplete },set:{ if !$0 { onboardingComplete = true } })) { OnboardingView { onboardingComplete = true } }.interactiveDismissDisabled(!onboardingComplete)
            .confirmationDialog("Debug tools",isPresented:$showDebug,titleVisibility:.visible) {
                Button("Run synthetic stitch test") { model.loadSample(runTest:true) }
                Button("Load sample capture") { model.loadSample(runTest:false) }
            }
            .confirmationDialog("Delete this capture and its original frames?",isPresented:Binding(get:{ deleting != nil },set:{ if !$0 { deleting = nil } }),titleVisibility:.visible) {
                Button("Delete capture",role:.destructive) { if let c = deleting { Task { await model.remove(c) } }; deleting = nil }
            }
            .alert("Action needed",isPresented:Binding(get:{ model.error != nil && model.selected == nil },set:{ if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
            .alert("Synthetic stitch metrics",isPresented:Binding(get:{ model.metrics != nil && model.selected == nil },set:{ if !$0 { model.metrics = nil } })) { Button("OK") { model.metrics = nil } } message: { Text(model.metrics ?? "") }
            .sheet(isPresented:Binding(get:{ model.shareURL != nil && model.selected == nil },set:{ if !$0 { model.shareURL = nil } })) { if let url = model.shareURL { ShareSheet(url:url) } }
        }
    }
}
struct Thumbnail: View {
    let id: UUID; let stitched: Bool
    @State private var image: UIImage?
    var body: some View {
        ZStack { Color.white.opacity(0.06); if let image { Image(uiImage:image).resizable().scaledToFill() } else { Image(systemName:"pano").foregroundStyle(Color.accentColor) } }
            .clipped().task(id:stitched) {
                guard stitched else { return }
                let url = CaptureStore.folder(id).appending(path:"panorama.jpg")
                image = await Task.detached { guard let raster = try? ImageCodec.decode(url,maxSize:160), let cg = try? ImageCodec.cgImage(raster) else { return nil as UIImage? }; return UIImage(cgImage:cg) }.value
            }
    }
}
struct OnboardingView: View {
    var finish: () -> Void
    @State private var step = 0
    let titles = ["Stand in one spot.","Turn around your phone, not your body.","Follow the dots."]
    let icons = ["figure.stand","iphone.gen3.radiowaves.left.and.right","circle.dotted"]
    var body: some View {
        VStack(spacing:32) {
            Spacer(); Image(systemName:icons[step]).font(.system(size:70)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text(titles[step]).font(.largeTitle).multilineTextAlignment(.center)
            Text(step == 2 ? "Camera access captures the scene. Optional location access aligns your panorama to true north." : "Keep the phone over the same point as you turn. Nearby objects and moving people can create seams.").foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer(); Button(step == 2 ? "Get started" : "Continue") { if step < 2 { step += 1 } else { finish() } }.buttonStyle(.borderedProminent).controlSize(.large)
            Text("\(step+1) of 3").font(.caption).foregroundStyle(.secondary)
        }.padding(32).preferredColorScheme(.dark)
    }
}
