import PalmCore
import SwiftUI

struct ResultsView: View {
    @State var document: TreeDocument
    let store: PackageStore
    @Environment(\.dismiss) private var dismiss
    @State private var csvURL: URL?
    @State private var identityURL: URL?
    @State private var annotationLogs: [URL] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Ringkasan") {
                    LabeledContent("Tandan unik", value: "\(document.clusters.count)")
                    LabeledContent("Kotak anotasi", value: "\(document.sides.flatMap(\.annotations).count)")
                    if document.run.type == .multiside {
                        let counts = ExportCodec.classCounts(document)
                        ForEach(Ripeness.allCases) { value in
                            LabeledContent(value == .unassigned ? "Belum diberi kelas" : value.label,
                                           value: "\(counts[value, default: 0])")
                        }
                    }
                }
                if document.run.type == .multiside {
                    let conflicting = document.clusters.enumerated().filter {
                        Set($0.element.compactMap { document.annotation($0)?.ripeness }).count > 1
                    }
                    if !conflicting.isEmpty {
                        Section("Perbedaan kelas") {
                            ForEach(conflicting, id: \.offset) { index, refs in
                                Menu("Tandan \(index + 1)") {
                                    ForEach(Ripeness.allCases.filter { $0 != .unassigned }) { value in
                                        Button(value.label) { resolve(refs, as: value) }
                                    }
                                }
                            }
                        }
                    }
                }
                Section("Ekspor sampel") {
                    if let csvURL, let identityURL {
                        ShareLink(item: csvURL) { Label("Bagikan CSV", systemImage: "tablecells") }
                        ShareLink(item: identityURL) { Label("Bagikan Identity JSON", systemImage: "curlybraces") }
                        ShareLink(items: annotationLogs) { Label("Bagikan log anotasi", systemImage: "list.bullet.rectangle") }
                    }
                    Button("Siapkan berkas", action: prepare)
                        .disabled(!document.isComplete)
                    if !document.isComplete { Text("Selesaikan sampel agar dapat diekspor.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Hasil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Tutup") { dismiss() } } }
            .modifier(ErrorAlert(message: $error))
        }
    }

    private func resolve(_ refs: [BoxRef], as value: Ripeness) {
        var updated = document
        for ref in refs { updated.setRipeness(ref, ripeness: value) }
        Task {
            do {
                document = try await store.save(updated)
                csvURL = nil
                identityURL = nil
                annotationLogs = []
            } catch { self.error = error.localizedDescription }
        }
    }

    private func prepare() {
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let csv = folder.appendingPathComponent(document.id + ".csv")
            let identity = folder.appendingPathComponent(document.id + "-identity.json")
            try ExportCodec.csv(document).write(to: csv, options: .atomic)
            try ExportCodec.identity(document).write(to: identity, options: .atomic)
            let logs = try document.sides.map { side in
                let url = folder.appendingPathComponent("\(document.id)_\(side.id + 1).json")
                try ExportCodec.annotLog(document, side: side).write(to: url, options: .atomic)
                return url
            }
            csvURL = csv
            identityURL = identity
            annotationLogs = logs
        } catch { self.error = error.localizedDescription }
    }
}
