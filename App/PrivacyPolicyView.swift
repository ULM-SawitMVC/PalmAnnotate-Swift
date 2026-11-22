import SwiftUI

struct PrivacyPolicyView: View {
    private static let paragraphs: [String] = {
        guard let url = Bundle.main.url(forResource: "PRIVACY", withExtension: "md"),
              let policy = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return policy.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n\n").dropFirst().map { $0 }
    }()

    var body: some View {
        ScrollView {
            if Self.paragraphs.isEmpty {
                ContentUnavailableView("Kebijakan privasi tidak tersedia", systemImage: "doc.text")
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Self.paragraphs, id: \.self) { paragraph in
                        if paragraph.hasPrefix("## ") {
                            Text(String(paragraph.dropFirst(3)))
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                        } else {
                            Text((try? AttributedString(markdown: paragraph)) ?? AttributedString(paragraph))
                        }
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Kebijakan Privasi")
        .navigationBarTitleDisplayMode(.inline)
    }
}
