import PalmCore
import SwiftUI

/// Kotlin `DeduplicationScreen`: seam suggestions scored and categorised, confirmed links removable,
/// and a compute step that resolves class mismatches before the results.
struct DedupSheet: View {
    let document: TreeDocument
    @Binding var clockwise: Bool
    let busy: Bool
    /// The editor's photos, so each suggestion can show both bunches like Kotlin's pair review.
    let images: SideImageCache
    let loadImage: (Int) async -> Void
    let onAccept: ([LinkSuggestion]) -> Void
    let onRemove: (String) -> Void
    /// Resolves class mismatches with the given choices (empty when there are none), saves, then shows results.
    let onCompute: ([String: Ripeness]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rejected: Set<String> = []
    @State private var showMismatch = false

    private var suggestions: [LinkSuggestion] {
        document.linkSuggestions(clockwise: clockwise).filter { !rejected.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            let suggestions = suggestions
            let auto = suggestions.filter { $0.category == .auto }
            let mismatches = document.classMismatches()
            List {
                Section {
                    Toggle("Arah tangkap searah jarum jam", isOn: $clockwise)
                }
                Section("Saran (\(suggestions.count))") {
                    if suggestions.isEmpty {
                        Text("Tidak ada saran tautan untuk pasangan foto ini.").foregroundStyle(.secondary)
                    } else {
                        Button("Terima semua otomatis (\(auto.count))", systemImage: "checkmark.circle") { onAccept(auto) }
                            .disabled(auto.isEmpty || busy)
                            .accessibilityIdentifier("dedup-accept-auto")
                    }
                    ForEach(suggestions) { suggestion in row(suggestion) }
                }
                let links = document.links
                if !links.isEmpty {
                    let groups = document.linkGroups()
                    Section("Tautan terkonfirmasi (\(links.count))") {
                        ForEach(links) { link in
                            HStack {
                                badge(number(link.a), group: groups[link.a] ?? 1)
                                Text(pairLabel(link.a, link.b))
                                Spacer()
                                Button {
                                    onRemove(link.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill").imageScale(.large)
                                }
                                .buttonStyle(.borderless)
                                .disabled(busy)
                                .accessibilityLabel("Hapus tautan \(pairLabel(link.a, link.b))")
                                .accessibilityIdentifier("dedup-remove-link-\(link.id)")
                            }
                        }
                    }
                }
                if !mismatches.isEmpty {
                    Section {
                        Label("\(mismatches.count) tandan memiliki kelas yang tidak konsisten antar sisi.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Dedup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Tutup") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hitung hasil") {
                        if mismatches.isEmpty { onCompute([:]) } else { showMismatch = true }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("dedup-compute")
                }
            }
            .sheet(isPresented: $showMismatch) {
                MismatchResolutionSheet(mismatches: mismatches, onApply: onCompute)
            }
            .task(id: clockwise) {
                for side in Set(suggestions.flatMap { [$0.a.side, $0.b.side] }).sorted() { await loadImage(side) }
            }
        }
    }

    private func row(_ suggestion: LinkSuggestion) -> some View {
        let tint: Color = suggestion.category == .auto ? .green : .orange
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                crop(suggestion.a)
                Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary)
                crop(suggestion.b)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pratinjau pasangan")
            .accessibilityIdentifier("dedup-pair-preview")
            HStack {
                Text(pairLabel(suggestion.a, suggestion.b))
                Spacer()
                Text("\(suggestion.percent)%").font(.headline.monospacedDigit()).foregroundStyle(tint)
                    .accessibilityIdentifier("dedup-score")
            }
            HStack {
                Text(suggestion.category == .auto ? "OTOMATIS" : "KANDIDAT")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(tint.opacity(0.18), in: .capsule)
                    .foregroundStyle(tint)
                    .accessibilityIdentifier("dedup-category")
                Spacer()
                Button("Tolak", role: .destructive) { rejected.insert(suggestion.id) }
                    .buttonStyle(.borderless)
                Button("Terima") { onAccept([suggestion]) }
                    .buttonStyle(.borderless)
                    .disabled(busy)
            }
        }
        .padding(.vertical, 2)
    }

    /// The bunch with a margin of context, cut from the downsampled photo. Box math stays in original pixels.
    private func crop(_ ref: BoxRef) -> some View {
        let cropped: UIImage? = {
            guard let image = images.image(ref.side)?.cgImage,
                  let side = document.sides.first(where: { $0.id == ref.side }), side.width > 0,
                  let rect = document.annotation(ref)?.rect else { return nil }
            let scale = CGFloat(image.width) / CGFloat(side.width)
            let width = CGFloat(rect.x2 - rect.x1)
            let height = CGFloat(rect.y2 - rect.y1)
            let margin = max(width, height) * 0.15
            let area = CGRect(x: CGFloat(rect.x1) - margin, y: CGFloat(rect.y1) - margin,
                              width: width + margin * 2, height: height + margin * 2)
            let pixels = CGRect(x: area.minX * scale, y: area.minY * scale, width: area.width * scale, height: area.height * scale)
                .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return image.cropping(to: pixels).map { UIImage(cgImage: $0) }
        }()
        return Group {
            if let cropped {
                Image(uiImage: cropped).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .background(.black, in: .rect(cornerRadius: 8))
        .clipShape(.rect(cornerRadius: 8))
    }

    private func badge(_ number: Int, group: Int) -> some View {
        Text("\(number)")
            .font(.caption.bold())
            .foregroundStyle(LinkPalette.textColor(group))
            .frame(width: 26, height: 26)
            .background(LinkPalette.color(group), in: .circle)
            .accessibilityHidden(true)
    }

    private func pairLabel(_ a: BoxRef, _ b: BoxRef) -> String {
        "Foto \(a.side + 1) · Tandan \(number(a))  ↔  Foto \(b.side + 1) · Tandan \(number(b))"
    }

    private func number(_ ref: BoxRef) -> Int {
        document.clusters.firstIndex { $0.contains(ref) }.map { $0 + 1 } ?? 0
    }
}
