import AVKit
import PalmCore
import SwiftUI

struct RunList: View {
    let type: DatasetType
    let store: PackageStore
    @State private var runs: [CollectionRun] = []
    @State private var counts: [String: (samples: Int, photos: Int)] = [:]
    @State private var showNew = false
    @State private var newRun: CollectionRun?
    @State private var pendingRun: CollectionRun?
    @State private var notice: String?
    @State private var error: String?
    @State private var confirmExportAll = false
    @State private var exporting = false
    @State private var exportURL: URL?

    var body: some View {
        List {
            if runs.isEmpty {
                ContentUnavailableView(type == .bunchWeight ? "Belum ada sesi berat" : "Belum ada sesi", systemImage: type.icon,
                                       description: Text("Buat sesi untuk mulai mengumpulkan data."))
            }
            ForEach(runs) { run in
                NavigationLink {
                    RunDetail(run: run, store: store)
                } label: {
                    VStack(alignment: .leading) {
                        Text("\(run.variety) · \(run.block)").font(.headline)
                        let count = counts[run.id] ?? (0, 0)
                        Text(type == .bunchWeight ? "\(count.samples) sampel · \(count.photos) foto"
                             : "\(count.samples) pohon · \(run.sideCount) foto/pohon")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let exportURL {
                Section {
                    ShareLink(item: exportURL) { Label("Bagikan ZIP semua sesi", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle(type.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if type != .bunchWeight && !runs.isEmpty {
                Button("Ekspor semua ZIP", systemImage: "archivebox") { confirmExportAll = true }
                    .disabled(exporting)
            }
            Button("Sesi baru", systemImage: "plus") { showNew = true }
        }
        .overlay {
            if exporting { ProgressView("Menyiapkan ZIP…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) }
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
            Button("Ekspor semua ZIP", action: exportAll)
        } message: {
            Text("Semua sampel selesai dari setiap sesi dan modul digabung dalam satu ZIP. Proses ini dapat memakan waktu.")
        }
        .alert("Sesi dilanjutkan", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
        .navigationDestination(item: $newRun) { run in
            RunDetail(run: run, store: store)
        }
        .task { await load() }
        .modifier(ErrorAlert(message: $error))
    }

    private func load() async {
        do {
            runs = try await store.runs(type: type)
            var result: [String: (Int, Int)] = [:]
            for run in runs {
                let trees = try await store.trees(runID: run.id)
                result[run.id] = (trees.count, trees.reduce(0) { $0 + $1.sides.count })
            }
            counts = result
        } catch { self.error = error.localizedDescription }
    }

    private func exportAll() {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                exportURL = try await store.export(runID: nil, to: FileManager.default.temporaryDirectory, appVersion: appVersion)
            } catch { self.error = error.localizedDescription }
        }
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
        return !match.captureSet.nameToken.isEmpty || (counts[match.id]?.samples ?? 0) > 0
    }

    private var preview: String {
        if let match, tokenLocked { return match.nextTreeName }
        let marker: String? = switch type {
        case .multiside: nil
        case .multisideVideo: "VID"
        case .bunchWeight: "BW"
        }
        let parts = [cleanVariety, cleanBlock, marker, tokenized ? token : nil, "0001"]
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
                    if let match {
                        LabeledContent("Jumlah foto", value: "\(match.sideCount)")
                    } else {
                        Picker("Jumlah foto", selection: $sideCount) {
                            ForEach(type.sideOptions, id: \.self) { Text("\($0)").tag($0) }
                        }
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
                                                    sideCount: match?.sideCount ?? sideCount, split: split, tokenized: tokenized)
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
        let count = defaults.integer(forKey: "newRun.sideCount.\(type.rawValue)")
        if type.sideOptions.contains(count) { sideCount = count }
    }

    private func rememberInput() {
        guard let defaults else { return }
        defaults.set(cleanVariety, forKey: "newRun.variety")
        defaults.set(cleanBlock, forKey: "newRun.block")
        defaults.set(operatorName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "newRun.operator")
        defaults.set(tokenized, forKey: "newRun.tokenized")
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
    @State private var exportURL: URL?
    @State private var exporting = false
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
            if documents.contains(where: \.isComplete) {
                Section {
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Bagikan ZIP", systemImage: "square.and.arrow.up") }
                    }
                    Button(exporting ? "Menyiapkan ZIP…" : "Buat ZIP", action: export)
                        .disabled(exporting)
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
            exportURL = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func export() {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                exportURL = try await store.export(runID: run.id, to: FileManager.default.temporaryDirectory, appVersion: appVersion)
            } catch { self.error = error.localizedDescription }
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
