import PalmCore
import SwiftUI

/// Kotlin `DeduplicationScreen`: seam suggestions scored and categorised, confirmed links removable,
/// and a compute step that resolves class mismatches before the results.
struct DedupSheet: View {
    let document: TreeDocument
    @Binding var clockwise: Bool
    let busy: Bool
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
        }
    }

    private func row(_ suggestion: LinkSuggestion) -> some View {
        let tint: Color = suggestion.category == .auto ? .green : .orange
        return VStack(alignment: .leading, spacing: 6) {
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
