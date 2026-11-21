import AVFoundation
import PhotosUI
import PalmCore
import SwiftUI
import UniformTypeIdentifiers

struct CaptureScreen: View {
    let run: CollectionRun
    let store: PackageStore
    let completed: (TreeDocument) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera = CaptureDevice()
    @State private var gps = CaptureLocation()
    @State private var draft: [CapturedPhoto] = []
    @State private var reviewedSide: Int?
    @State private var replacement: Int?
    @State private var recording = false
    @State private var savedVideo = false
    @State private var ready = false
    @State private var busy = true
    @State private var busyLabel = "Menyiapkan kamera…"
    @State private var error: String?
    @State private var captureError: String?
    @State private var showDiscard = false
    @State private var qualityReport: QualityCheck.Report?
    #if targetEnvironment(simulator)
    @State private var fixture: PhotosPickerItem?
    @State private var showMovieImporter = false
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(draft.count) / \(run.sideCount) foto").font(.headline)
                    if recording {
                        Label("Merekam", systemImage: "record.circle.fill").foregroundStyle(.red)
                    }
                    if let reviewedSide, draft.indices.contains(reviewedSide),
                       let image = UIImage(data: draft[reviewedSide].jpeg) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 420)
                            .frame(maxWidth: .infinity).background(.black, in: .rect(cornerRadius: 12))
                            .accessibilityLabel("Foto \(reviewedSide + 1)")
                    } else if ready {
                        CameraPreview(camera: camera).aspectRatio(4 / 3, contentMode: .fit)
                            .frame(maxHeight: 360).clipShape(.rect(cornerRadius: 12))
                            .accessibilityLabel("Pratinjau kamera")
                    } else if let captureError {
                        Text(captureError).foregroundStyle(.secondary)
                    }
                    if !draft.isEmpty { photoButtons }
                    captureActions
                    if busy {
                        ProgressView(busyLabel).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(run.type.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Tutup") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .topBarTrailing) {
                    if !draft.isEmpty && !recording {
                        Button("Hapus draf", systemImage: "trash", role: .destructive) { showDiscard = true }
                            .disabled(busy)
                    }
                }
            }
            .alert("Hapus draf?", isPresented: $showDiscard) {
                Button("Batal", role: .cancel) {}
                Button("Hapus", role: .destructive) { work("Menghapus draf…") { try await clearDraft() } }
            }
            .modifier(ErrorAlert(message: $error))
            .qualityReview($qualityReport, question: "Simpan tetap?", continueTitle: "Simpan tetap", onContinue: commit)
            .interactiveDismissDisabled(recording || busy)
            .task { await open() }
            .onDisappear { camera.stop() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    camera.stop()
                    ready = false
                    if recording {
                        recording = false
                        self.error = CaptureError.recordingInterrupted.localizedDescription
                    }
                } else if phase == .active, !ready, !busy {
                    work("Menyiapkan kamera…") { await startCamera() }
                }
            }
            #if targetEnvironment(simulator)
            .onChange(of: fixture) { _, item in
                guard let item else { return }
                work("Memuat foto…") {
                    defer { fixture = nil }
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw CaptureError.photo }
                    try await savePhoto(data)
                }
            }
            .fileImporter(isPresented: $showMovieImporter, allowedContentTypes: [.mpeg4Movie]) { result in
                work("Memeriksa video…") {
                    let url = try result.get()
                    let editing = url.startAccessingSecurityScopedResource()
                    defer { if editing { url.stopAccessingSecurityScopedResource() } }
                    let asset = AVURLAsset(url: url)
                    let audio = try await asset.loadTracks(withMediaType: .audio)
                    let video = try await asset.loadTracks(withMediaType: .video)
                    guard !audio.isEmpty, !video.isEmpty else { throw CaptureError.video }
                    try await store.saveDraftVideo(from: url, runID: run.id)
                    savedVideo = true
                }
            }
            #endif
        }
    }

    private var photoButtons: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(draft.indices, id: \.self) { index in
                    Button("Foto \(index + 1)") { reviewedSide = index }
                        .buttonStyle(.borderedProminent)
                        .tint(reviewedSide == index ? .accentColor : .secondary)
                }
            }
        }
        .disabled(recording || busy)
    }

    @ViewBuilder
    private var captureActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if run.type.requiresVideo && !recording && !savedVideo {
                Button("Mulai rekam", systemImage: "record.circle") {
                    work("Memulai rekaman…") {
                        try await clearDraft()
                        try await camera.startVideo(rotation: rotation) {
                            // The system ended the recording (a call, another camera client, or full
                            // storage). Photos taken during it cannot be saved without their video.
                            guard recording else { return }
                            recording = false
                            error = CaptureError.recordingInterrupted.localizedDescription
                        }
                        recording = true
                    }
                }
                .disabled(!ready)
            }
            if recording {
                Button("Hentikan rekaman", systemImage: "stop.circle") {
                    work("Menyimpan video…") {
                        recording = false
                        let url = try await camera.finishVideo()
                        defer { try? FileManager.default.removeItem(at: url) }
                        try await store.saveDraftVideo(from: url, runID: run.id)
                        savedVideo = true
                        reviewedSide = draft.indices.last
                    }
                }
                .disabled(draft.count != run.sideCount)
            }
            if let reviewedSide, !recording, !run.type.requiresVideo || savedVideo {
                Button("Ambil ulang foto \(reviewedSide + 1)", systemImage: "arrow.clockwise") {
                    replacement = reviewedSide
                    self.reviewedSide = nil
                }
                if draft.count < run.sideCount {
                    Button("Lanjut ke foto \(draft.count + 1)") { self.reviewedSide = nil; replacement = nil }
                }
            }
            if reviewedSide == nil && (replacement != nil || draft.count < run.sideCount)
                && (!run.type.requiresVideo || recording || savedVideo) {
                Button("Ambil foto", systemImage: "camera") {
                    work("Memproses foto…") {
                        try await savePhoto(camera.takePhoto(rotation: rotation))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ready)
            }
            #if targetEnvironment(simulator)
            if reviewedSide == nil && (replacement != nil || draft.count < run.sideCount) {
                PhotosPicker(selection: $fixture, matching: .images) { Label("Pilih foto simulator", systemImage: "photo") }
            }
            if run.type.requiresVideo && !savedVideo && draft.count == run.sideCount {
                Button("Pilih video MP4 simulator", systemImage: "video") { showMovieImporter = true }
            }
            #endif
            if canSave {
                Button(run.type == .bunchWeight && draft.count == 1 ? "Simpan dengan 1 foto" : "Simpan sampel",
                       systemImage: "checkmark", action: requestSave)
                .buttonStyle(.borderedProminent)
            }
        }
        .disabled(busy)
    }

    private var canSave: Bool {
        !recording && (run.type.requiresVideo ? savedVideo :
            draft.count == run.sideCount || (run.type == .bunchWeight && !draft.isEmpty))
    }

    private var rotation: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        return CameraPreview.PreviewView.rotation(for: scene?.interfaceOrientation ?? .portrait)
    }

    private func open() async {
        defer { busy = false }
        do {
            draft = try await store.draftPhotos(runID: run.id)
            savedVideo = await store.draftVideo(runID: run.id) != nil
            reviewedSide = draft.indices.last
        } catch { self.error = error.localizedDescription }
        #if DEBUG
        if !ProcessInfo.processInfo.arguments.contains("--ui-test") { gps.refresh() }
        #else
        gps.refresh()
        #endif
        await startCamera()
    }

    private func startCamera() async {
        #if targetEnvironment(simulator)
        captureError = "Pilih foto untuk mensimulasikan tangkapan kamera."
        #else
        do {
            try await camera.start(withVideo: run.type.requiresVideo)
            ready = true
            captureError = nil
        } catch { captureError = error.localizedDescription }
        #endif
    }

    private func savePhoto(_ data: Data) async throws {
        var photo = try normalizedPhoto(data)
        if !run.type.requiresVideo {
            do {
                let boxes = try await Detector.shared.detect(photo)
                photo = CapturedPhoto(jpeg: photo.jpeg, width: photo.width, height: photo.height, suggestions: boxes)
            } catch {
                self.error = error.localizedDescription + " Foto tersimpan dan dapat dianotasi manual."
            }
        }
        let index = replacement ?? draft.count
        try await store.saveDraftPhoto(photo, runID: run.id, side: index)
        if index == draft.count { draft.append(photo) }
        else { draft[index] = photo }
        replacement = nil
        if !recording { reviewedSide = index }
    }

    /// Kotlin `CaptureFlowViewModel.requestSave`: review WARN and ERROR reports before committing.
    private func requestSave() {
        let report = QualityCheck.analyzeCapture(run: run, capturedSides: draft.count, gps: gps.provenance.atCommit(.now))
        if report.needsReview { qualityReport = report } else { commit() }
    }

    private func commit() {
        work("Menyimpan sampel…") {
            let document = try await store.commitCapture(runID: run.id, gps: gps.provenance)
            completed(document)
            dismiss()
        }
    }

    private func clearDraft() async throws {
        try await store.discardDraft(runID: run.id)
        draft = []
        reviewedSide = nil
        replacement = nil
        savedVideo = false
    }

    private func work(_ label: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        busyLabel = label
        Task {
            defer { busy = false }
            do { try await operation() }
            catch { self.error = error.localizedDescription }
        }
    }
}
