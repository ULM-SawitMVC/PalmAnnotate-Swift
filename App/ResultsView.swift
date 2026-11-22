import PalmCore
import SwiftUI

struct ResultsView: View {
    @State var document: TreeDocument
    let store: PackageStore
    @Environment(\.dismiss) private var dismiss
    @State private var exports: [Int: SampleExport] = [:]
    @State private var exportRequest: TreeDocument?
    @State private var error: String?
    @State private var qualityReport: QualityCheck.Report?
    @State private var showMismatch = false

    var body: some View {
        NavigationStack {
            List {
                Section("Ringkasan") {
                    let total = document.sides.flatMap(\.annotations).count
                    LabeledContent("Tandan unik", value: "\(document.clusters.count)")
                    LabeledContent("Total deteksi", value: "\(total)")
                    LabeledContent("Duplikat tertaut", value: "\(total - document.clusters.count)")
                        .accessibilityIdentifier("results-linked-duplicates")
                    if document.run.type == .multiside {
                        let counts = ExportCodec.classCounts(document)
                        ForEach(Ripeness.allCases) { value in
                            LabeledContent(value == .unassigned ? "Belum diberi kelas" : value.label,
                                           value: "\(counts[value, default: 0])")
                        }
                    }
                }
                Section("Per sisi") {
                    ForEach(document.sides) { side in
                        LabeledContent("Foto \(side.id + 1)", value: "\(side.annotations.count)")
                    }
                }
                let mismatches = document.classMismatches()
                if !mismatches.isEmpty {
                    Section("Perbedaan kelas") {
                        Label("\(mismatches.count) tandan memiliki kelas yang tidak konsisten antar sisi.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Selesaikan perbedaan kelas", systemImage: "checklist") { showMismatch = true }
                            .accessibilityIdentifier("results-resolve-mismatch")
                    }
                }
                Section("Ekspor sampel") {
                    if let files = exports[document.revision] {
                        ShareLink(item: files.csv) { Label("Bagikan CSV", systemImage: "tablecells") }
                        ShareLink(item: files.identity) { Label("Bagikan Identity JSON", systemImage: "curlybraces") }
                        ShareLink(items: files.logs) { Label("Bagikan log anotasi", systemImage: "list.bullet.rectangle") }
                        ShareLink(item: files.output) { Label("Bagikan Output JSON", systemImage: "doc.text") }
                        ShareLink(items: files.labels) { Label("Bagikan label YOLO", systemImage: "square.dashed") }
                    }
                    Button("Siapkan berkas", action: requestExport)
                        .disabled(exportRequest != nil)
                    if !document.isComplete {
                        Text("Sampel masih draf. Berkas tetap dapat disiapkan, tetapi periksa hasilnya terlebih dahulu.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("results-list")
            .navigationTitle("Hasil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Tutup") { dismiss() } } }
            .modifier(ErrorAlert(message: $error))
            .sheet(isPresented: $showMismatch) {
                MismatchResolutionSheet(mismatches: document.classMismatches(), applyTitle: "Terapkan") { choices in
                    resolve(choices)
                }
            }
            .qualityReview($qualityReport, question: "Ekspor tetap?", continueTitle: "Ekspor tetap", onContinue: prepare)
        }
        .task(id: exportRequest?.revision) { await prepareRequestedExport() }
        .onDisappear { exportRequest = nil }
    }

    private func resolve(_ choices: [String: Ripeness]) {
        var updated = document
        updated.resolveClassMismatches(choices)
        Task {
            do {
                document = try await store.save(updated)
                exportRequest = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func requestExport() {
        let report = QualityCheck.analyzeTree(document)
        if report.needsReview { qualityReport = report } else { prepare() }
    }

    private func prepare() {
        guard exports[document.revision] == nil else { return }
        exportRequest = document
    }

    private func prepareRequestedExport() async {
        guard let snapshot = exportRequest else { return }
        defer {
            if !Task.isCancelled, exportRequest?.revision == snapshot.revision { exportRequest = nil }
        }
        let worker = Task.detached(priority: .userInitiated) { try SampleExport.prepare(snapshot) }
        do {
            let files = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            guard document.revision == snapshot.revision else { return }
            // Keep previous revisions alive until Results closes so shares can finish reading them.
            exports[snapshot.revision] = files
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

private final class SampleExport: Sendable {
    private let folder: URL
    let csv: URL
    let identity: URL
    let logs: [URL]
    let output: URL
    let labels: [URL]

    private init(_ document: TreeDocument) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.folder = folder
        csv = folder.appendingPathComponent(document.id + "_result.csv")
        identity = folder.appendingPathComponent(document.id + "_identity.json")
        output = folder.appendingPathComponent(document.id + ".json")
        logs = document.sides.map { folder.appendingPathComponent("\(document.id)_\($0.id + 1).json") }
        labels = document.sides.map { folder.appendingPathComponent("\(document.id)_\($0.id + 1).txt") }
    }

    static func prepare(_ document: TreeDocument) throws -> SampleExport {
        try Task.checkCancellation()
        let files = SampleExport(document)
        try FileManager.default.createDirectory(at: files.folder, withIntermediateDirectories: true)
        try ExportCodec.csv(document).write(to: files.csv, options: .atomic)
        try ExportCodec.identity(document).write(to: files.identity, options: .atomic)
        try ExportCodec.output(document, generatedAt: document.savedAt).write(to: files.output, options: .atomic)
        for (index, side) in document.sides.enumerated() {
            try Task.checkCancellation()
            try ExportCodec.annotLog(document, side: side).write(to: files.logs[index], options: .atomic)
            try ExportCodec.labels(side, type: document.run.type).write(to: files.labels[index], options: .atomic)
        }
        try Task.checkCancellation()
        return files
    }

    deinit {
        let folder = folder
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
