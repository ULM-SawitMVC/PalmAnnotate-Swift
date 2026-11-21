import AVKit
import PalmCore
import SwiftUI

/// One ZIP export at a time: progress, cancellation, and the hand-off to the share sheet.
@MainActor @Observable
final class ExportJob {
    private(set) var running = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var treeName = ""
    private(set) var readyURL: URL?
    var notice: String?
    var error: String?
    private var task: Task<Void, Never>?
    private var shareOnDismiss = false

    func start(store: PackageStore, runID: String?) {
        guard !running else { return }
        discardArchive()
        running = true
        (done, total, treeName, notice, error) = (0, 0, "", nil, nil)
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            defer {
                running = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do {
                #if DEBUG
                // Gives UI tests a window in which the progress sheet is visible and can be cancelled.
                if ProcessInfo.processInfo.arguments.contains("--ui-test-slow-export") {
                    try await Task.sleep(for: .seconds(3))
                }
                #endif
                let url = try await store.export(runID: runID, to: FileManager.default.temporaryDirectory,
                                                 appVersion: appVersion) { done, total, name in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.update(done, total, name) } }
                }
                readyURL = url
                shareOnDismiss = true
            } catch is CancellationError {
                notice = "Ekspor dibatalkan"
            } catch StoreError.emptyExport {
                error = StoreError.emptyExport.errorDescription
            } catch {
                self.error = "Ekspor gagal: \(error.localizedDescription)"
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Forgets a finished archive once the data it was built from may have changed.
    func reset() {
        guard !running else { return }
        discardArchive()
        notice = nil
    }

    func presentShareIfReady() {
        guard shareOnDismiss, let readyURL else { return }
        shareOnDismiss = false
        ShareSheet.present(readyURL)
    }

    private func update(_ done: Int, _ total: Int, _ name: String) {
        guard running else { return }
        self.done = max(self.done, done)
        self.total = total
        treeName = name
    }

    private func discardArchive() {
        if let readyURL { try? FileManager.default.removeItem(at: readyURL.deletingLastPathComponent()) }
        readyURL = nil
        shareOnDismiss = false
    }
}

@MainActor
private enum ShareSheet {
    static func present(_ url: URL) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow ?? scenes.first?.keyWindow,
              var top = window.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = top.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        top.present(controller, animated: true)
    }
}

private struct ExportProgressSheet: View {
    let job: ExportJob

    var body: some View {
        VStack(spacing: 16) {
            Text("Menyiapkan ZIP…").font(.headline)
            ProgressView(value: Double(job.done), total: Double(max(job.total, 1)))
            Text(job.total == 0 ? "Memeriksa berkas…" : "\(job.done)/\(job.total) berkas · \(job.treeName)")
                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("export-status")
            Text("Biarkan layar tetap menyala sampai selesai.").font(.footnote).foregroundStyle(.secondary)
            Button("Batal", role: .cancel) { job.cancel() }.buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: 480)
        .interactiveDismissDisabled()
        .presentationDetents([.height(280)])
        .accessibilityIdentifier("export-progress")
    }
}

private struct ExportPresenter: ViewModifier {
    @Bindable var job: ExportJob

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { job.running }, set: { _ in }), onDismiss: { job.presentShareIfReady() }) {
                ExportProgressSheet(job: job)
            }
            .modifier(ErrorAlert(message: $job.error))
    }
}

/// The result rows shared by both export entry points.
private struct ExportResult: View {
    let job: ExportJob
    let shareTitle: String

    var body: some View {
        if let url = job.readyURL {
            Label("ZIP siap: \(url.lastPathComponent)", systemImage: "checkmark.seal")
                .accessibilityIdentifier("export-ready")
            ShareLink(item: url) { Label(shareTitle, systemImage: "square.and.arrow.up") }
        }
        if let notice = job.notice {
            Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("export-notice")
        }
    }
}

struct RunList: View {
    let type: DatasetType
    let store: PackageStore
    @State private var summaries: [RunSummary] = []
    @State private var allSamples = 0
    @State private var showNew = false
    @State private var newRun: CollectionRun?
    @State private var pendingRun: CollectionRun?
    @State private var notice: String?
    @State private var error: String?
    @State private var confirmExportAll = false
    @State private var pendingDelete: RunSummary?
    @State private var job = ExportJob()

    private var runs: [CollectionRun] { summaries.map(\.run) }
    private var counts: [String: (samples: Int, photos: Int)] {
        Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, ($0.treeCount, $0.photoCount)) })
    }
    private var sampleNoun: String { type == .bunchWeight ? "sampel" : "pohon" }

    var body: some View {
        List {
            if job.readyURL != nil || job.notice != nil {
                Section { ExportResult(job: job, shareTitle: "Bagikan ZIP semua sesi") }
            }
            if summaries.isEmpty {
                ContentUnavailableView(type == .bunchWeight ? "Belum ada sesi berat" : "Belum ada sesi", systemImage: type.icon,
                                       description: Text("Buat sesi untuk mulai mengumpulkan data."))
            } else {
                Section {
                    HStack {
                        stat("Sesi", summaries.count)
                        stat(type == .bunchWeight ? "Sampel" : "Pohon", summaries.reduce(0) { $0 + $1.treeCount })
                        stat("Foto", summaries.reduce(0) { $0 + $1.photoCount })
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("run-stats")
                }
            }
            ForEach(summaries) { summary in
                let run = summary.run
                NavigationLink {
                    RunDetail(run: run, store: store)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(run.variety) · \(run.block)").font(.headline)
                        Text(type == .bunchWeight ? "\(summary.treeCount) sampel · \(summary.photoCount) foto"
                             : "\(summary.treeCount) pohon · \(run.sideCount) foto/pohon")
                            .foregroundStyle(.secondary)
                        Text(summary.updatedAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Hapus", role: .destructive) { pendingDelete = summary }
                }
                .contextMenu {
                    Button("Hapus", systemImage: "trash", role: .destructive) { pendingDelete = summary }
                }
            }
        }
        .navigationTitle(type.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if type != .bunchWeight && !runs.isEmpty {
                Button("Ekspor semua ZIP", systemImage: "archivebox") { confirmExportAll = true }
                    .disabled(job.running)
            }
            Button("Sesi baru", systemImage: "plus") { showNew = true }
        }
        .sheet(isPresented: $showNew, onDismiss: {
            newRun = pendingRun
            pendingRun = nil
            Task { await load() }
        }) {
            NewRun(type: type, store: store, existing: runs, counts: counts) { run, resumed in
                pendingRun = run
                if resumed {
                    notice = "Melanjutkan sesi yang ada untuk blok \(run.block) · berikutnya: \(run.nextTreeName)"
                }
            }
        }
        .alert("Ekspor seluruh dataset?", isPresented: $confirmExportAll) {
            Button("Batal", role: .cancel) {}
            Button("Ekspor semua ZIP") { job.start(store: store, runID: nil) }
        } message: {
            Text("Semua \(allSamples) pohon dan sampel dari setiap sesi dan modul digabung dalam satu ZIP (foto, label, JSON). Proses ini dapat memakan waktu; biarkan layar tetap menyala sampai selesai.")
        }
        .alert("Hapus sesi?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Batal", role: .cancel) { pendingDelete = nil }
            Button("Hapus", role: .destructive) {
                guard let item = pendingDelete else { return }
                pendingDelete = nil
                Task {
                    do {
                        try await store.deleteRun(id: item.id)
                        job.reset()
                        await load()
                    } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            if let item = pendingDelete {
                Text("Hapus \(item.run.variety) · \(item.run.block) beserta \(item.treeCount) \(sampleNoun)? Foto\(type.requiresVideo ? ", video," : "") dan keluaran tersimpan ikut terhapus. Tindakan ini tidak dapat dibatalkan.")
            }
        }
        .alert("Sesi dilanjutkan", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
        .navigationDestination(item: $newRun) { run in
            RunDetail(run: run, store: store)
        }
        .task { await load() }
        .modifier(ExportPresenter(job: job))
        .modifier(ErrorAlert(message: $error))
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack {
            Text("\(value)").font(.title2.bold().monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            summaries = try await store.summaries(type: type)
            var samples = 0
            for module in DatasetType.allCases { samples += try await store.summaries(type: module).reduce(0) { $0 + $1.treeCount } }
            allSamples = samples
        } catch { self.error = error.localizedDescription }
    }
}

private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

private struct NewRun: View {
    let type: DatasetType
    let store: PackageStore
    let existing: [CollectionRun]
    let counts: [String: (samples: Int, photos: Int)]
    let onSave: (CollectionRun, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var variety = ""
    @State private var block = ""
    @State private var operatorName = ""
    @State private var split = "field"
    @State private var sideCount = 0
    @State private var tokenized = false
    @State private var autoId = true
    @State private var token = ""
    @State private var error: String?
    @State private var saving = false

    private var cleanVariety: String { CollectionRun.sanitizedVariety(variety) }
    private var cleanBlock: String { CollectionRun.sanitizedBlock(block) }
    private var match: CollectionRun? { existing.first { $0.variety == cleanVariety && $0.block == cleanBlock } }
    private var blockError: String? {
        switch cleanBlock {
        case "BW": "BW dipakai untuk nama sampel berat tandan."
        case "VID": "VID dipakai untuk nama pohon multisisi video."
        default: nil
        }
    }

    /// Mirrors `PackageStore.createRun`: a started run keeps its naming, and an unstarted one adopts the token.
    private var tokenLocked: Bool {
        guard let match else { return false }
        return !match.captureSet.nameToken.isEmpty || (counts[match.id]?.samples ?? 0) > 0 || match.nextNumber != 1
    }

    private var preview: String {
        if let match, tokenLocked { return match.nextTreeName }
        let marker: String? = switch type {
        case .multiside: nil
        case .multisideVideo: "VID"
        case .bunchWeight: "BW"
        }
        let number = String(format: "%04d", match?.nextNumber ?? 1)
        let parts = [cleanVariety, cleanBlock, marker, tokenized ? token : nil, number]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "_")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identitas") {
                    TextField("Varietas", text: $variety).textInputAutocapitalization(.characters)
                    TextField("Blok", text: $block).textInputAutocapitalization(.characters)
                    if let blockError, !block.isEmpty {
                        Text(blockError).font(.footnote).foregroundStyle(.red)
                    }
                    TextField("Nama operator (opsional)", text: $operatorName)
                }
                Section("Pengambilan") {
                    if type.sideOptions.count == 1 {
                        if type == .bunchWeight {
                            Text("Dua foto per sampel; foto kedua boleh dilewati.").font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if let match {
                        LabeledContent("Jumlah foto", value: "\(match.sideCount)")
                    } else {
                        Picker("Jumlah foto", selection: $sideCount) {
                            ForEach(type.sideOptions, id: \.self) { Text("\($0)").tag($0) }
                        }
                    }
                    Toggle("ID otomatis", isOn: match.map { .constant($0.autoId) } ?? $autoId)
                        .disabled(match != nil)
                        .accessibilityIdentifier("auto-id-toggle")
                    if !(match?.autoId ?? autoId) {
                        Text("Nomor \(type == .bunchWeight ? "sampel" : "pohon") diketik sendiri saat pengambilan.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Tambahkan \(token) ke nama", isOn: tokenLocked ? .constant(!(match?.captureSet.nameToken.isEmpty ?? true)) : $tokenized)
                        .disabled(tokenLocked)
                    if tokenLocked {
                        Text("Penamaan sudah tetap untuk sesi ini.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !cleanVariety.isEmpty && !cleanBlock.isEmpty {
                    Section {
                        Text("\(match == nil ? (type == .bunchWeight ? "Sampel" : "Pohon") : "Berikutnya"): \(preview)")
                            .font(.callout.bold().monospaced())
                            .accessibilityIdentifier("name-preview")
                    }
                }
            }
            .navigationTitle(type == .bunchWeight ? "Sesi berat baru" : "Sesi baru")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Batal") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Simpan", action: save)
                        .disabled(saving || cleanVariety.isEmpty || cleanBlock.isEmpty || blockError != nil)
                }
            }
            .task {
                if sideCount == 0 { sideCount = type.sideOptions[0] }
                token = await store.deviceToken
                restoreLastInput()
            }
            .modifier(ErrorAlert(message: $error))
        }
    }

    private func save() {
        saving = true
        let resumed = match != nil
        Task {
            defer { saving = false }
            do {
                let run = try await store.createRun(type: type, variety: variety, block: block, operatorName: operatorName,
                                                    sideCount: match?.sideCount ?? sideCount, split: split, tokenized: tokenized,
                                                    autoId: autoId)
                rememberInput()
                onSave(run, resumed)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // Kotlin `InputCache`: the next session starts from the previous entries.
    private var defaults: UserDefaults? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test") { return nil }
        #endif
        return .standard
    }

    private func restoreLastInput() {
        guard let defaults, variety.isEmpty, block.isEmpty else { return }
        variety = defaults.string(forKey: "newRun.variety") ?? "DAMIMAS"
        block = defaults.string(forKey: "newRun.block") ?? ""
        operatorName = defaults.string(forKey: "newRun.operator") ?? ""
        tokenized = defaults.bool(forKey: "newRun.tokenized")
        autoId = defaults.object(forKey: "newRun.autoId") as? Bool ?? true
        let count = defaults.integer(forKey: "newRun.sideCount.\(type.rawValue)")
        if type.sideOptions.contains(count) { sideCount = count }
    }

    private func rememberInput() {
        guard let defaults else { return }
        defaults.set(cleanVariety, forKey: "newRun.variety")
        defaults.set(cleanBlock, forKey: "newRun.block")
        defaults.set(operatorName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "newRun.operator")
        defaults.set(tokenized, forKey: "newRun.tokenized")
        defaults.set(autoId, forKey: "newRun.autoId")
        defaults.set(sideCount, forKey: "newRun.sideCount.\(type.rawValue)")
    }
}

struct RunDetail: View {
    let run: CollectionRun
    let store: PackageStore
    @State private var documents: [TreeDocument] = []
    @State private var showCapture = false
    @State private var captureOnReturn = false
    @State private var selectedID: TreeID?
    @State private var pendingCaptureID: TreeID?
    @State private var nextTreeName = ""
    @State private var error: String?
    @State private var job = ExportJob()
    @State private var pendingDelete: TreeDocument?

    private struct TreeID: Hashable { let value: String }
    private var sampleNoun: String { run.type == .bunchWeight ? "sampel" : "pohon" }

    var body: some View {
        List {
            Section {
                Button {
                    showCapture = true
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Tangkap sampel", systemImage: "camera")
                        if !nextTreeName.isEmpty { Text(nextTreeName).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section {
                LabeledContent(run.type == .bunchWeight ? "Sampel" : "Pohon", value: "\(documents.count)")
                LabeledContent("Foto", value: "\(documents.reduce(0) { $0 + $1.sides.count })")
                LabeledContent("Selesai", value: "\(documents.filter(\.isComplete).count)")
                if !run.operatorName.isEmpty { LabeledContent("Operator", value: run.operatorName) }
                if !run.autoId { LabeledContent("ID \(sampleNoun)", value: "Manual") }
            } header: {
                Label("\(run.variety) · \(run.block) · terkunci untuk sesi ini", systemImage: "lock")
            }
            Section(run.type == .bunchWeight ? "Sampel" : "Pohon") {
                if documents.isEmpty {
                    Text(run.type == .bunchWeight ? "Belum ada sampel." : "Belum ada pohon. Ketuk “Tangkap sampel” untuk memulai.")
                        .foregroundStyle(.secondary)
                }
                ForEach(documents) { document in
                    NavigationLink {
                        destination(document.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(document.id).font(.headline)
                                Text("\(document.sides.count) foto · \(document.isComplete ? "Selesai" : "Draf")")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if document.isComplete {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Selesai")
                            }
                        }
                    }
                    .swipeActions {
                        Button("Hapus", role: .destructive) { pendingDelete = document }
                    }
                    .contextMenu {
                        Button("Hapus", systemImage: "trash", role: .destructive) { pendingDelete = document }
                    }
                }
            }
            if !documents.isEmpty {
                Section {
                    ExportResult(job: job, shareTitle: "Bagikan ZIP")
                    Button(job.running ? "Menyiapkan ZIP…" : "Buat ZIP") { job.start(store: store, runID: run.id) }
                        .disabled(job.running)
                } footer: {
                    Text("Semua \(sampleNoun), termasuk yang masih draf, masuk ke ZIP.")
                }
            }
        }
        .navigationTitle("\(run.variety) · \(run.block)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCapture, onDismiss: {
            selectedID = pendingCaptureID
            pendingCaptureID = nil
            Task { await load() }
        }) {
            CaptureScreen(run: run, store: store) { document in
                pendingCaptureID = TreeID(value: document.id)
            }
        }
        .navigationDestination(item: $selectedID) { choice in destination(choice.value) }
        .task { await load() }
        .onAppear {
            guard captureOnReturn else { return }
            captureOnReturn = false
            showCapture = true
        }
        .alert("Hapus \(sampleNoun)?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Batal", role: .cancel) { pendingDelete = nil }
            Button("Hapus", role: .destructive) {
                guard let item = pendingDelete else { return }
                pendingDelete = nil
                Task {
                    do {
                        try await store.deleteTree(id: item.id)
                        await load()
                    } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            if let item = pendingDelete {
                Text("\(item.id) dan \(item.sides.count) fotonya akan dihapus\(item.video == nil ? "" : " beserta videonya"). Tindakan ini tidak dapat dibatalkan.")
            }
        }
        .modifier(ExportPresenter(job: job))
        .modifier(ErrorAlert(message: $error))
    }

    @ViewBuilder
    private func destination(_ id: String) -> some View {
        if run.type.requiresVideo {
            VideoSampleView(id: id, store: store)
        } else {
            AnnotationEditor(id: id, store: store) { captureOnReturn = true }
        }
    }

    private func load() async {
        do {
            documents = try await store.trees(runID: run.id)
            nextTreeName = try await store.run(id: run.id).nextTreeName
            job.reset()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Kotlin `VideoTreeViewer`: a read-only pager of the photos with a switch to the recording.
private struct VideoSampleView: View {
    let id: String
    let store: PackageStore
    @State private var player: AVPlayer?
    @State private var photos: [URL] = []
    @State private var page: Int? = 0
    @State private var showVideo = false
    @State private var videoFailed = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if showVideo {
                    if videoFailed {
                        Text("Video ini tidak dapat diputar.").foregroundStyle(.white)
                    } else if let player {
                        VideoPlayer(player: player).accessibilityIdentifier("video-player")
                    }
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(Array(photos.enumerated()), id: \.offset) { index, url in
                                Group {
                                    if let photo = UIImage(contentsOfFile: url.path) {
                                        Image(uiImage: photo).resizable().scaledToFit()
                                    } else {
                                        Text("Foto tidak dapat dibaca.").foregroundStyle(.white)
                                    }
                                }
                                .containerRelativeFrame([.horizontal, .vertical])
                                .accessibilityLabel("Foto \(index + 1) / \(photos.count)")
                                .id(index)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $page)
                    .scrollIndicators(.hidden)
                    .accessibilityIdentifier("video-photo-pager")
                }
            }
            HStack {
                if !showVideo {
                    Text("Foto \((page ?? 0) + 1) / \(photos.count)").font(.headline.monospacedDigit())
                        .accessibilityIdentifier("video-photo-counter")
                }
                Spacer()
                Button(showVideo ? "Foto" : "Putar video", systemImage: showVideo ? "photo" : "play.fill") {
                    showVideo.toggle()
                    if showVideo { player?.play() } else { player?.pause() }
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 48)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle(id)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let url = await store.videoURL(treeID: id)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            videoFailed = size == 0
            if !videoFailed {
                let asset = AVURLAsset(url: url)
                videoFailed = !((try? await asset.load(.isPlayable)) ?? false)
                if !videoFailed { player = AVPlayer(playerItem: AVPlayerItem(asset: asset)) }
            }
            if photos.isEmpty, let tree = try? await store.tree(id: id) {
                for side in tree.sides { photos.append(await store.photoURL(treeID: id, side: side.id)) }
            }
        }
        .onDisappear { player?.pause() }
    }
}
