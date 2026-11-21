import PalmCore
import SwiftUI

struct ResultsView: View {
    @State var document: TreeDocument
    let store: PackageStore
    @Environment(\.dismiss) private var dismiss
    @State private var csvURL: URL?
    @State private var identityURL: URL?
    @State private var annotationLogs: [URL] = []
    @State private var outputURL: URL?
    @State private var labelURLs: [URL] = []
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
                    if let csvURL, let identityURL {
                        ShareLink(item: csvURL) { Label("Bagikan CSV", systemImage: "tablecells") }
                        ShareLink(item: identityURL) { Label("Bagikan Identity JSON", systemImage: "curlybraces") }
                        ShareLink(items: annotationLogs) { Label("Bagikan log anotasi", systemImage: "list.bullet.rectangle") }
                        if let outputURL {
                            ShareLink(item: outputURL) { Label("Bagikan Output JSON", systemImage: "doc.text") }
                        }
                        ShareLink(items: labelURLs) { Label("Bagikan label YOLO", systemImage: "square.dashed") }
                    }
                    Button("Siapkan berkas", action: requestExport)
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
    }

    private func resolve(_ choices: [String: Ripeness]) {
        var updated = document
        updated.resolveClassMismatches(choices)
        Task {
            do {
                document = try await store.save(updated)
                csvURL = nil
                identityURL = nil
                annotationLogs = []
                outputURL = nil
                labelURLs = []
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Kotlin `ResultsViewModel.exportGated`: review any non-OK tree report before exporting.
    private func requestExport() {
        let report = QualityCheck.analyzeTree(document)
        if report.needsReview { qualityReport = report } else { prepare() }
    }

    private func prepare() {
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let csv = folder.appendingPathComponent(document.id + "_result.csv")
            let identity = folder.appendingPathComponent(document.id + "_identity.json")
            try ExportCodec.csv(document).write(to: csv, options: .atomic)
            try ExportCodec.identity(document).write(to: identity, options: .atomic)
            let logs = try document.sides.map { side in
                let url = folder.appendingPathComponent("\(document.id)_\(side.id + 1).json")
                try ExportCodec.annotLog(document, side: side).write(to: url, options: .atomic)
                return url
            }
            // Kotlin's Output JSON and YOLO exports write the same files the ZIP carries under json/ and labels/.
            let output = folder.appendingPathComponent(document.id + ".json")
            try ExportCodec.output(document, generatedAt: document.savedAt).write(to: output, options: .atomic)
            let labels = try document.sides.map { side in
                let url = folder.appendingPathComponent("\(document.id)_\(side.id + 1).txt")
                try ExportCodec.labels(side, type: document.run.type).write(to: url, options: .atomic)
                return url
            }
            csvURL = csv
            identityURL = identity
            annotationLogs = logs
            outputURL = output
            labelURLs = labels
        } catch { self.error = error.localizedDescription }
    }
}
