import SwiftUI
import Geometry

struct DetailView: View {
    @State var document: CaptureDocument
    let library: LibraryViewModel
    @StateObject private var viewer = PanoramaController()
    @State private var previewImage: CGImage?
    @State private var previewError: String?
    @State private var editing: Hotspot?
    @State private var showSettings = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                if document.stitched {
                    Group {
                        if let previewImage { PanoramaView(image:previewImage,hotspots:document.hotspots,controller:viewer) }
                        else { ProgressView("Loading panorama") }
                    }.frame(minHeight:220).task { await loadPreview() }
                    HStack {
                        Text(String(format:"Yaw %.1f° · Pitch %.1f°",Geometry.wrap(viewer.look.yaw),viewer.look.pitch)).font(.caption.monospacedDigit())
                        Spacer(); Toggle("Gyro",isOn:$viewer.gyro).fixedSize().accessibilityLabel("Gyroscope magic window")
                    }.padding()
                    if let metrics = library.metrics { Text(metrics).font(.caption.monospaced()).padding(.horizontal) }
                    Text("Tap to tag · Drag a dot to move it").font(.caption).foregroundStyle(.secondary)
                    List {
                        ForEach(document.hotspots) { dot in
                            Button { editing = dot } label: { VStack(alignment:.leading,spacing:4) { Text(dot.title).foregroundStyle(.primary); Text(dot.caption).font(.caption).foregroundStyle(.secondary) } }
                        }.onDelete { offsets in document.hotspots.remove(atOffsets:offsets); persist() }
                    }.frame(minHeight:100,maxHeight:220)
                } else {
                    ContentUnavailableView("Ready to stitch",systemImage:"pano",description:Text("\(document.frames.count) photographs are stored on this iPhone."))
                }
                HStack {
                    Button(document.stitched ? "Re-stitch" : "Stitch",systemImage:"pano") { library.stitch(document); dismiss() }.disabled(document.frames.isEmpty)
                    Spacer()
                    Button("Export",systemImage:"square.and.arrow.up") { library.export(document) }.disabled(!document.stitched)
                }.buttonStyle(.borderedProminent).padding()
            }
            .overlay {
                if let progress = library.progress {
                    ZStack {
                        Color.black.opacity(0.6).ignoresSafeArea()
                        VStack(spacing: 20) {
                            ProgressView(value: progress)
                            Text(library.activity)
                            Button("Cancel") { library.work?.cancel() }
                        }.padding(30).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24)).padding(36)
                    }
                }
            }
            .navigationTitle(document.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement:.topBarTrailing) { Button("Settings",systemImage:"slider.horizontal.3") { showSettings = true }.labelStyle(.iconOnly) }
            }
            .onAppear {
                viewer.onTap = { angle in editing = Hotspot(view:document.slug,title:"",yaw:Geometry.wrap(angle.yaw),pitch:angle.pitch,caption:"") }
                viewer.onMove = { id, angle in
                    guard let index = document.hotspots.firstIndex(where: { $0.id == id }) else { return }
                    document.hotspots[index].yaw = Geometry.wrap(angle.yaw); document.hotspots[index].pitch = angle.pitch
                }
            }
            .onDisappear { viewer.stop(); persist() }
            .alert("Preview needs attention",isPresented:Binding(get:{ previewError != nil },set:{ if !$0 { previewError = nil } })) {
                Button("Retry") { Task { await loadPreview() } }; Button("Close",role:.cancel) { dismiss() }
            } message: { Text(previewError ?? "") }
            .alert("Gyroscope viewing",isPresented:Binding(get:{ viewer.error != nil },set:{ if !$0 { viewer.error = nil } })) {
                Button("OK") { viewer.error = nil }
            } message: { Text(viewer.error ?? "") }
            .alert("Action needed",isPresented:Binding(get:{ library.error != nil },set:{ if !$0 { library.error = nil } })) {
                Button("OK") { library.error = nil }
            } message: { Text(library.error ?? "") }
            .sheet(item:$editing) { dot in HotspotEditor(dot:dot,others:document.hotspots) { edited in document.hotspots.removeAll { $0.id == edited.id }; document.hotspots.append(edited); persist() } }
            .sheet(isPresented:$showSettings) { settings }
            .sheet(isPresented:Binding(get:{ library.shareURL != nil },set:{ if !$0 { library.shareURL = nil } })) { if let url = library.shareURL { ShareSheet(url:url) } }
        }
    }
    private func loadPreview() async {
        let url = CaptureStore.folder(document.id).appending(path:"panorama.jpg")
        do { previewImage = try await Task.detached { try ImageCodec.cgImage(ImageCodec.decode(url,maxSize:4096)) }.value }
        catch { previewError = error.localizedDescription }
    }
    private func persist() { let value = document; Task { await library.save(value) } }
    private var settings: some View {
        NavigationStack {
            Form {
                TextField("Capture name",text:$document.name)
                Picker("Panorama width",selection:$document.settings.width) { ForEach([2048,4096,6144],id:\.self) { Text("\($0) px").tag($0) } }
                Toggle("Include raw frames in export",isOn:$document.settings.includeFrames)
                Toggle("MIRAS nadir cap",isOn:$document.settings.nadirCap)
                Toggle("Refine rotations (slower)",isOn:$document.settings.refinement)
                Text("Size, cap, and refinement apply on the next stitch.").font(.caption).foregroundStyle(.secondary)
                if !document.warnings.isEmpty { Section("Capture notes") { ForEach(document.warnings,id:\.self) { Text($0) } } }
                if document.stitched {
                    Button("Save panorama to Photos",systemImage:"photo.badge.plus") {
                        Task { do { try await library.exporter.saveToPhotos(document) } catch { library.error = error.localizedDescription } }
                    }
                }
                Text("Coverage \(document.coverage*100,specifier:"%.1f")% · \(document.yawReference)")
            }.navigationTitle("Capture settings").toolbar { Button("Done") { persist(); showSettings = false } }
        }
    }
}
struct HotspotEditor: View {
    @State var dot: Hotspot
    let others: [Hotspot]
    var save: (Hotspot) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sourceText = ""
    private var near: Bool { others.contains { $0.id != dot.id && SphericalAngle(yaw:$0.yaw,pitch:$0.pitch).distance(to:.init(yaw:dot.yaw,pitch:dot.pitch)) < 12 } }
    private var valid: Bool {
        !dot.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !dot.caption.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && dot.caption.count <= 300 && sources.allSatisfy { URL(string:$0)?.scheme.map { ["https","http"].contains($0) } == true }
    }
    private var sources: [String] { sourceText.split(whereSeparator:\.isNewline).map(String.init) }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Title (required)",text:$dot.title)
                Section("Caption (required, up to 300 characters)") { TextEditor(text:$dot.caption).frame(minHeight:120).accessibilityLabel("Hotspot caption"); Text("\(dot.caption.count) / 300").foregroundStyle(dot.caption.count > 300 ? .red : .secondary) }
                Section("Sources: one URL per line") { TextEditor(text:$sourceText).frame(minHeight:80).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Source URLs") }
                Text(String(format:"Yaw %.1f° · Pitch %.1f°",dot.yaw,dot.pitch))
                if near { Label("Another hotspot is less than 12° away.",systemImage:"exclamationmark.triangle").foregroundStyle(.orange) }
            }.navigationTitle("Hotspot").toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Save") { dot.sources = sources; save(dot); dismiss() }.disabled(!valid) }
            }.onAppear { sourceText = dot.sources.joined(separator:"\n") }
        }
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems:[url],applicationActivities:nil) }
    func updateUIViewController(_ controller: UIActivityViewController,context: Context) { }
}
