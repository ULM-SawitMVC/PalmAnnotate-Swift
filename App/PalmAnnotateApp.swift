import PalmCore
import SwiftUI

@main
struct PalmAnnotateApp: App {
    var body: some Scene {
        WindowGroup {
            PalmAnnotateRoot()
        }
    }
}

private struct PalmAnnotateRoot: View {
    @State private var store: PackageStore?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            if let store {
                List {
                    Section("Pilih alur pengumpulan data") {
                        ForEach(DatasetType.allCases) { module in
                            NavigationLink {
                                RunList(type: module, store: store)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(module.title, systemImage: module.icon).font(.headline)
                                    Text(module.detail).font(.subheadline).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 8)
                            }
                        }
                    }
                }
                .navigationTitle("PalmAnnotate")
                .safeAreaInset(edge: .bottom) { hubFooter }
            } else if let error {
                ContentUnavailableView("Penyimpanan tidak tersedia", systemImage: "externaldrive.badge.exclamationmark", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .task {
            guard store == nil else { return }
            do {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                             appropriateFor: nil, create: true)
                var base = directory.appendingPathComponent("PalmAnnotate")
                #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--ui-test") {
                    base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                }
                #endif
                let opened = try PackageStore(root: base)
                #if DEBUG
                if arguments.contains("--ui-test-capture") { try await seedCaptureFixture(opened) }
                if arguments.contains("--ui-test-collections") { try await seedCollectionsFixture(opened) }
                if arguments.contains("--ui-test-quality") { try await seedQualityReviewFixture(opened) }
                if arguments.contains("--ui-test-manual-id") { try await seedManualIDFixture(opened) }
                #endif
                store = opened
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var hubFooter: some View {
        VStack(spacing: 4) {
            Text("Data hanya tersimpan di aplikasi ini. Ekspor ZIP untuk memindahkan data.")
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("hub-data-hint")
            Text(versionLabel).monospacedDigit().accessibilityIdentifier("hub-version")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = "v\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        guard let revision = info?["PalmSourceRevision"] as? String else { return version }
        return "\(version) · \(revision)"
    }

    #if DEBUG
    private func seedCollectionsFixture(_ store: PackageStore) async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 90)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        }
        let run = try await store.createRun(type: .multiside, variety: "DAMIMAS", block: "A1", operatorName: "",
                                            sideCount: 4, split: "field", tokenized: false)
        _ = try await store.createRun(type: .multiside, variety: "DAMIMAS", block: "B2", operatorName: "",
                                      sideCount: 4, split: "field", tokenized: false)
        for _ in 0..<2 {
            for side in 0..<4 {
                try await store.saveDraftPhoto(CapturedPhoto(jpeg: image, width: 120, height: 90), runID: run.id, side: side)
            }
            _ = try await store.commitCapture(runID: run.id, gps: Provenance(status: .unavailable))
        }
    }

    private func seedCaptureFixture(_ store: PackageStore) async throws {
        let run = try await store.createRun(type: .bunchWeight, variety: "DAMIMAS", block: "QA", operatorName: "",
                                            sideCount: 2, split: "field", tokenized: false)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 360)).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 360))
            UIColor.systemBrown.setFill()
            context.fill(CGRect(x: 170, y: 110, width: 140, height: 140))
        }
        let photo = try normalizedPhoto(image)
        _ = try await Detector.shared.detect(photo)
        try await store.saveDraftPhoto(photo, runID: run.id, side: 0)
        var tree = try await store.commitCapture(runID: run.id, gps: Provenance(status: .unavailable))
        let centerX = Float(photo.width) / 2
        let centerY = Float(photo.height) / 2
        _ = tree.addBox(side: 0, rect: PixelBox(x1: centerX - 100, y1: centerY - 100, x2: centerX + 100, y2: centerY + 100))
        _ = try await store.save(tree)
    }
    #endif
}

extension DatasetType {
    var title: String {
        switch self {
        case .multiside: "Multisisi"
        case .multisideVideo: "Multisisi Video"
        case .bunchWeight: "Berat Tandan"
        }
    }

    var detail: String {
        switch self {
        case .multiside: "Foto pohon dari 4 atau 8 sisi"
        case .multisideVideo: "Foto multisisi dan rekaman video"
        case .bunchWeight: "Foto, berat, dan ukuran tandan"
        }
    }

    var icon: String {
        switch self {
        case .multiside: "camera"
        case .multisideVideo: "video"
        case .bunchWeight: "scalemass"
        }
    }
}

struct ErrorAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert("PalmAnnotate", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}
