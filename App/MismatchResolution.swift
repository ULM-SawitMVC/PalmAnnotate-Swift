import PalmCore
import SwiftUI

/// Kotlin `MismatchResolveModal`: each linked bunch with inconsistent classes lists its members, and the
/// operator picks one class for the whole bunch. Chips start on the majority class.
struct MismatchResolutionSheet: View {
    let mismatches: [ClassMismatch]
    let applyTitle: String
    let onApply: ([String: Ripeness]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picks: [String: Ripeness]

    init(mismatches: [ClassMismatch], applyTitle: String = "Terapkan & lanjut", onApply: @escaping ([String: Ripeness]) -> Void) {
        self.mismatches = mismatches
        self.applyTitle = applyTitle
        self.onApply = onApply
        _picks = State(initialValue: Dictionary(uniqueKeysWithValues: mismatches.map { ($0.id, $0.majority) }))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(mismatches.count) tandan memiliki kelas yang tidak konsisten antar sisi. Pilih kelas yang benar untuk setiap tandan.")
                        .accessibilityIdentifier("mismatch-body")
                }
                ForEach(Array(mismatches.enumerated()), id: \.element.id) { index, mismatch in
                    Section("Tandan \(index + 1)") {
                        let pick = picks[mismatch.id] ?? mismatch.majority
                        ForEach(Array(mismatch.members.enumerated()), id: \.offset) { _, member in
                            Text("Foto \(member.ref.side + 1) · \(member.ripeness.label)")
                                .font(.body.bold())
                                .foregroundStyle(member.ripeness == pick ? Color.green : Color.red)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Pilih kelas akhir:").font(.footnote).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                ForEach(choices(for: mismatch)) { value in chip(value, for: mismatch, pick: pick, number: index + 1) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Penyelesaian kelas tandan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Batal") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(applyTitle) {
                        onApply(picks)
                        dismiss()
                    }
                    .accessibilityIdentifier("mismatch-apply")
                }
            }
        }
        .presentationDetents([.large])
    }

    private func choices(for mismatch: ClassMismatch) -> [Ripeness] {
        Ripeness.allCases.filter { $0 != .unassigned || mismatch.observed.contains(.unassigned) }
    }

    private func chip(_ value: Ripeness, for mismatch: ClassMismatch, pick: Ripeness, number: Int) -> some View {
        let selected = pick == value
        return Button {
            picks[mismatch.id] = value
        } label: {
            Text(value.label)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .tint(selected ? ripenessColor(value) : .secondary.opacity(mismatch.observed.contains(value) ? 0.5 : 0.25))
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 8).stroke(.primary, lineWidth: 3) }
        }
        .accessibilityIdentifier("mismatch-\(number)-\(value.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
