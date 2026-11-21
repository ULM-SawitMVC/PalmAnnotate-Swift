import AVKit
import PalmCore
import SwiftUI

struct RunList: View {
    let type: DatasetType
    let store: PackageStore
    @State private var runs: [CollectionRun] = []
    @State private var showNew = false
    @State private var newRun: CollectionRun?
    @State private var pendingRun: CollectionRun?
    @State private var error: String?

    var body: some View {
        List {
            if runs.isEmpty {
                ContentUnavailableView("Belum ada sesi", systemImage: type.icon,
                                       description: Text("Buat sesi untuk mulai mengumpulkan data."))
            }
            ForEach(runs) { run in
                NavigationLink {
                    RunDetail(run: run, store: store)
                } label: {
                    VStack(alignment: .leading) {
                        Text("\(run.variety) · \(run.block)").font(.headline)
                        Text("\(run.sideCount) foto · \(run.split)").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(type.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Sesi baru", systemImage: "plus") { showNew = true }
        }
        .sheet(isPresented: $showNew, onDismiss: {
            newRun = pendingRun
            pendingRun = nil
            Task { await load() }
        }) {
            NewRun(type: type, store: store) { pendingRun = $0 }
        }
        .navigationDestination(item: $newRun) { run in
            RunDetail(run: run, store: store)
        }
        .task { await load() }
        .modifier(ErrorAlert(message: $error))
    }

    private func load() async {
        do { runs = try await store.runs(type: type) }
        catch { self.error = error.localizedDescription }
    }
}

private struct NewRun: View {
    let type: DatasetType
    let store: PackageStore
    let onSave: (CollectionRun) -> Void
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

    var body: some View {
        NavigationStack {
            Form {
                Section("Identitas") {
                    TextField("Varietas", text: $variety).textInputAutocapitalization(.characters)
                    TextField("Blok", text: $block).textInputAutocapitalization(.characters)
                    TextField("Nama operator (opsional)", text: $operatorName)
                }
                Section("Pengambilan") {
                    Picker("Jumlah foto", selection: $sideCount) {
                        ForEach(type.sideOptions, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Toggle("Sertakan kode perangkat", isOn: $tokenized)
                    if tokenized { Text("Kode perangkat: \(token)").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Sesi baru")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Batal") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Simpan", action: save)
                        .disabled(saving || CollectionRun.sanitizedVariety(variety).isEmpty || CollectionRun.sanitizedBlock(block).isEmpty)
                }
            }
            .task {
                if sideCount == 0 { sideCount = type.sideOptions[0] }
                token = await store.deviceToken
            }
            .modifier(ErrorAlert(message: $error))
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                let run = try await store.createRun(type: type, variety: variety, block: block, operatorName: operatorName,
                                                    sideCount: sideCount, split: split, tokenized: tokenized)
                onSave(run)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct RunDetail: View {
    let run: CollectionRun
    let store: PackageStore
    @State private var documents: [TreeDocument] = []
    @State private var showCapture = false
    @State private var selectedID: TreeID?
    @State private var pendingCaptureID: TreeID?
    @State private var nextTreeName = ""
    @State private var error: String?
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var pendingDelete: TreeDocument?

    private struct TreeID: Hashable { let value: String }

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
            Section("Sampel") {
                if documents.isEmpty {
                    Text("Belum ada sampel.").foregroundStyle(.secondary)
                }
                ForEach(documents) { document in
                    NavigationLink {
                        destination(document.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(document.id).font(.headline)
                            Text("\(document.sides.count) foto · \(document.isComplete ? "Selesai" : "Draf")")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Hapus", role: .destructive) { pendingDelete = document }
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
        .alert("Hapus sampel?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
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
        } message: { Text(pendingDelete?.id ?? "") }
        .modifier(ErrorAlert(message: $error))
    }

    @ViewBuilder
    private func destination(_ id: String) -> some View {
        if run.type.requiresVideo {
            VideoSampleView(id: id, store: store)
        } else {
            AnnotationEditor(id: id, store: store)
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
                exportURL = try await store.export(runID: run.id, to: FileManager.default.temporaryDirectory,
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct VideoSampleView: View {
    let id: String
    let store: PackageStore
    @State private var player: AVPlayer?
    @State private var photos: [URL] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let player { VideoPlayer(player: player).aspectRatio(16 / 9, contentMode: .fit) }
                ForEach(Array(photos.enumerated()), id: \.offset) { index, url in
                    if let photo = UIImage(contentsOfFile: url.path) {
                        Text("Foto \(index + 1)").font(.headline)
                        Image(uiImage: photo).resizable().scaledToFit()
                    }
                }
            }.padding()
        }
        .navigationTitle(id)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            player = await AVPlayer(url: store.videoURL(treeID: id))
            if let tree = try? await store.tree(id: id) {
                for side in tree.sides { photos.append(await store.photoURL(treeID: id, side: side.id)) }
            }
        }
        .onDisappear { player?.pause() }
    }
}
