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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var camera = CaptureDevice()
    @State private var gps = CaptureLocation()
    @State private var draft: [CapturedPhoto] = []
    @State private var previews: [Int: UIImage] = [:]
    @State private var thumbnails: [Int: UIImage] = [:]
    @State private var reviewedSide: Int?
    @State private var replacement: Int?
    @State private var recording = false
    @State private var recordingStarted: Date?
    @State private var savedVideo = false
    @State private var draftInvalid = false
    @State private var ready = false
    @State private var busy = true
    @State private var busyLabel = "Menyiapkan kamera…"
    @State private var error: String?
    @State private var captureError: String?
    @State private var permissionDenied = false
    @State private var showDiscard = false
    @State private var showRetakeAll = false
    @State private var showStopRecording = false
    @State private var qualityReport: QualityCheck.Report?
    @State private var manualID = ""
    @FocusState private var editingID: Bool
    @State private var detections: [Int: Task<Void, Never>] = [:]
    @State private var detectionNotice: String?
    #if targetEnvironment(simulator)
    @State private var fixture: PhotosPickerItem?
    @State private var showMovieImporter = false
    #endif

    var body: some View {
        NavigationStack {
            layout
            .navigationTitle(run.type.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") { if recording { showStopRecording = true } else { dismiss() } }
                        .disabled(busy && !recording)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Selesai") { editingID = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if (!draft.isEmpty || draftInvalid) && !recording {
                        Button("Hapus draf", systemImage: "trash", role: .destructive) { showDiscard = true }
                            .disabled(busy)
                    }
                }
            }
            .alert("Hapus draf?", isPresented: $showDiscard) {
                Button("Batal", role: .cancel) {}
                Button("Hapus", role: .destructive) { work("Menghapus draf…") { try await clearDraft() } }
            }
            .alert("Ambil ulang semua foto dengan rekaman baru?", isPresented: $showRetakeAll) {
                Button("Batal", role: .cancel) {}
                Button("Rekam ulang", role: .destructive, action: startRecording)
            } message: {
                Text("Foto dan video draf ini akan dihapus. Setiap foto harus diambil selama rekaman yang sama.")
            }
            .alert("Hentikan rekaman dan buang video?", isPresented: $showStopRecording) {
                Button("Lanjut merekam", role: .cancel) {}
                Button("Buang", role: .destructive) {
                    recording = false
                    camera.stop()
                    dismiss()
                }
            } message: {
                Text("Foto yang diambil selama rekaman ini tidak dapat disimpan tanpa videonya.")
            }
            .modifier(ErrorAlert(message: $error))
            .qualityReview($qualityReport, question: "Simpan tetap?", continueTitle: "Simpan tetap", onContinue: commit)
            .interactiveDismissDisabled(recording || busy)
            .task { await open() }
            .onDisappear {
                camera.stop()
                for task in detections.values { task.cancel() }
                UIApplication.shared.isIdleTimerDisabled = false
            }
            .onChange(of: recording) { _, value in
                UIApplication.shared.isIdleTimerDisabled = value
                recordingStarted = value ? .now : nil
            }
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

    // MARK: Sections

    private var sideBySide: Bool { verticalSizeClass == .compact }

    @ViewBuilder
    private var layout: some View {
        if sideBySide {
            HStack(alignment: .top, spacing: 16) {
                stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        status
                        controls
                    }
                    .padding(.vertical)
                }
                .frame(width: 320)
            }
            .padding(.horizontal)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    status
                    stage
                    controls
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        header
        if !run.autoId { manualIDField }
        if draftInvalid { invalidDraftBanner }
        if recording, let recordingStarted { recordingIndicator(since: recordingStarted) }
    }

    @ViewBuilder
    private var controls: some View {
        if !draft.isEmpty { thumbnailStrip }
        captureActions
        if busy {
            ProgressView(busyLabel).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(draft.count) / \(run.sideCount) foto").font(.headline)
            Label("\(run.variety) · \(run.block)", systemImage: "lock")
                .font(.subheadline).foregroundStyle(.secondary)
            if !detections.isEmpty {
                Label("Mendeteksi tandan…", systemImage: "sparkle.magnifyingglass")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("detection-pending")
            } else if let detectionNotice {
                Label(detectionNotice, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
                    .accessibilityIdentifier("detection-notice")
            }
            TimelineView(.periodic(from: .now, by: 15)) { context in
                HStack(spacing: 8) {
                    Label(gps.describe(at: context.date), systemImage: gpsSymbol)
                        .font(.footnote)
                        .foregroundStyle(gpsColor)
                        .accessibilityIdentifier("gps-status")
                    if gps.provenance.status == .permissionDenied || gps.provenance.status == .locationOff {
                        Button("Pengaturan", action: openSettings).font(.footnote)
                    }
                }
            }
        }
    }

    private var manualIDField: some View {
        HStack {
            Spacer()
            Text(run.type == .bunchWeight ? "ID sampel" : "ID pohon")
                .font(.subheadline).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(run.type == .bunchWeight ? "ID sampel" : "ID pohon", text: $manualID)
                .keyboardType(.numberPad)
                .focused($editingID)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onChange(of: manualID) { _, value in
                    let digits = value.filter(\.isASCII).filter(\.isNumber)
                    if digits != value { manualID = digits }
                }
                .disabled(busy || recording)
                .accessibilityLabel(run.type == .bunchWeight ? "ID sampel" : "ID pohon")
                .accessibilityIdentifier("manual-tree-id")
        }
    }

    private var gpsSymbol: String {
        switch gps.provenance.status {
        case .fresh: "location.fill"
        case .stale: "location"
        default: "location.slash"
        }
    }

    private var gpsColor: Color {
        switch gps.provenance.atCommit(.now).status {
        case .fresh: .secondary
        case .stale: .orange
        default: .red
        }
    }

    private var invalidDraftBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Draf tangkapan tidak valid. Hapus draf untuk mulai lagi.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Button("Hapus draf", role: .destructive) { showDiscard = true }
                .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1), in: .rect(cornerRadius: 12))
        .accessibilityIdentifier("invalid-draft")
    }

    private func recordingIndicator(since start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            Label("Merekam \(seconds / 60):\(String(format: "%02d", seconds % 60))", systemImage: "record.circle.fill")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.red)
                .accessibilityIdentifier("recording-indicator")
        }
    }

    @ViewBuilder
    private var stage: some View {
        if let reviewedSide, draft.indices.contains(reviewedSide) {
            reviewPager(selection: reviewedSide)
        } else if ready {
            CameraPreview(camera: camera).aspectRatio(4 / 3, contentMode: .fit)
                .frame(maxHeight: sideBySide ? .infinity : 360).clipShape(.rect(cornerRadius: 12))
                .accessibilityLabel("Pratinjau kamera")
        } else if let captureError {
            VStack(alignment: .leading, spacing: 8) {
                Text(captureError).foregroundStyle(.secondary)
                if permissionDenied { Button("Buka Pengaturan", action: openSettings) }
            }
        }
    }

    private func reviewPager(selection: Int) -> some View {
        let binding = Binding<Int>(get: { reviewedSide ?? selection }, set: { reviewedSide = $0 })
        return TabView(selection: binding) {
            ForEach(draft.indices, id: \.self) { index in
                Group {
                    if let image = previews[index] {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Foto \(index + 1)")
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: draft.count > 1 ? .always : .never))
        .frame(height: sideBySide ? nil : 420)
        .background(.black, in: .rect(cornerRadius: 12))
        .overlay(alignment: .topLeading) {
            Text("Foto \(selection + 1)/\(run.sideCount)")
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.7), in: .capsule)
                .foregroundStyle(.white)
                .padding(8)
        }
        .disabled(recording)
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.indices, id: \.self) { index in
                    Button { reviewedSide = index } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if let image = thumbnails[index] {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Color.secondary.opacity(0.3)
                                }
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(.rect(cornerRadius: 8))
                            Text("\(index + 1)")
                                .font(.caption2.bold())
                                .padding(3)
                                .background(.black.opacity(0.7), in: .rect(cornerRadius: 4))
                                .foregroundStyle(.white)
                                .padding(3)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(reviewedSide == index ? Color.accentColor : .clear, lineWidth: 3)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Foto \(index + 1)")
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
                    if draft.isEmpty { startRecording() } else { showRetakeAll = true }
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
                if draft.count != run.sideCount {
                    Text("Ambil \(run.sideCount - draft.count) foto lagi sebelum menghentikan rekaman.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
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
        .disabled(busy || draftInvalid)
    }

    private var canSave: Bool {
        !recording && (run.type.requiresVideo ? savedVideo :
            draft.count == run.sideCount || (run.type == .bunchWeight && !draft.isEmpty))
    }

    private var rotation: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        return CameraPreview.PreviewView.rotation(for: scene?.interfaceOrientation ?? .portrait)
    }

    // MARK: Actions

    private func open() async {
        defer { busy = false }
        do {
            if !run.autoId, manualID.isEmpty, let current = try? await store.run(id: run.id) {
                manualID = String(current.nextNumber)
            }
            draft = try await store.draftPhotos(runID: run.id)
            savedVideo = await store.draftVideo(runID: run.id) != nil
            reviewedSide = draft.count < run.sideCount ? nil : draft.indices.last
            for index in draft.indices { render(index) }
        } catch {
            draftInvalid = true
        }
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
            permissionDenied = false
        } catch {
            captureError = error.localizedDescription
            permissionDenied = error as? CaptureError == .camera || error as? CaptureError == .microphone
        }
        #endif
    }

    private func startRecording() {
        work("Memulai rekaman…") {
            try await clearDraft()
            try await camera.startVideo(rotation: rotation) {
                guard recording else { return }
                recording = false
                error = CaptureError.recordingInterrupted.localizedDescription
            }
            recording = true
        }
    }

    private func savePhoto(_ data: Data) async throws {
        let photo = try normalizedPhoto(data)
        let index = replacement ?? draft.count
        try await store.saveDraftPhoto(photo, runID: run.id, side: index)
        if index == draft.count { draft.append(photo) }
        else { draft[index] = photo }
        render(index)
        replacement = nil
        if !recording { reviewedSide = index }
        if !run.type.requiresVideo { detect(photo, side: index) }
    }

    private func detect(_ photo: CapturedPhoto, side: Int) {
        detections[side]?.cancel()
        let runID = run.id
        let task = Task {
            do {
                let boxes = try await Detector.shared.detect(photo)
                try Task.checkCancellation()
                if await store.updateDraftSuggestions(runID: runID, side: side, jpeg: photo.jpeg, suggestions: boxes),
                   draft.indices.contains(side), draft[side].jpeg == photo.jpeg {
                    draft[side] = CapturedPhoto(jpeg: photo.jpeg, width: photo.width, height: photo.height, suggestions: boxes)
                }
            } catch is CancellationError {
            } catch {
                detectionNotice = "Deteksi otomatis gagal untuk foto \(side + 1). Foto tersimpan dan dapat dianotasi manual."
            }
        }
        detections[side] = task
        Task {
            await task.value
            if detections[side] == task { detections[side] = nil }
        }
    }

    private func render(_ index: Int) {
        guard draft.indices.contains(index) else { return }
        previews[index] = previewImage(draft[index].jpeg, maxPixel: 1600)
        thumbnails[index] = previewImage(draft[index].jpeg, maxPixel: 168)
    }

    private func requestSave() {
        let report = QualityCheck.analyzeCapture(run: run, capturedSides: draft.count, gps: gps.provenance.atCommit(.now))
        if report.needsReview { qualityReport = report } else { commit() }
    }

    private func commit() {
        work("Menyimpan sampel…") {
            if !detections.isEmpty {
                busyLabel = "Menunggu deteksi…"
                for task in detections.values { await task.value }
                busyLabel = "Menyimpan sampel…"
            }
            var treeNumber: Int?
            if !run.autoId {
                let fallback = (try? await store.run(id: run.id))?.nextNumber ?? 1
                treeNumber = max(1, Int(manualID) ?? fallback)
            }
            do {
                let document = try await store.commitCapture(runID: run.id, gps: gps.provenance, treeNumber: treeNumber)
                completed(document)
                dismiss()
            } catch {
                throw SaveFailure(detail: error.localizedDescription)
            }
        }
    }

    private func clearDraft() async throws {
        for task in detections.values { task.cancel() }
        detections = [:]
        detectionNotice = nil
        try await store.discardDraft(runID: run.id)
        draft = []
        previews = [:]
        thumbnails = [:]
        reviewedSide = nil
        replacement = nil
        savedVideo = false
        draftInvalid = false
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
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

private struct SaveFailure: LocalizedError {
    let detail: String
    var errorDescription: String? { "Sampel tidak dapat disimpan. Periksa penyimpanan lalu coba lagi. (\(detail))" }
}
