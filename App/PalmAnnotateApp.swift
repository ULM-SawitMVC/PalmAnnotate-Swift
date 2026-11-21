import SwiftUI

@main
struct PalmAnnotateApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List(DatasetModule.allCases, id: \.self) { module in
                    NavigationLink(value: module) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(module.title, systemImage: module.icon)
                                .font(.headline)
                            Text(module.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .navigationTitle("PalmAnnotate")
                .navigationDestination(for: DatasetModule.self) { module in
                    ContentUnavailableView {
                        Label("Pengumpulan data belum tersedia", systemImage: module.icon)
                    }
                    .navigationTitle(module.title)
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }
}

private enum DatasetModule: CaseIterable {
    case multiside, multisideVideo, bunchWeight

    var title: LocalizedStringKey {
        switch self {
        case .multiside: "Multisisi"
        case .multisideVideo: "Multisisi Video"
        case .bunchWeight: "Berat Tandan"
        }
    }

    var detail: LocalizedStringKey {
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
